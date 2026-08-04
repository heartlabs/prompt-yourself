// Notifications: local foreground reminders (always available) and Web Push
// via the optional Rust server (real background notifications on iOS).
//
// Server contract (see server/src/main.rs):
//   GET  /api/health            → { ok: true }        server present?
//   GET  /api/status            → { subscriptions, vapid_subject, schedule, … }
//   POST /api/test-push         → immediate push; per-subscription results
//   GET  /api/vapid-public-key  → { key }             for pushManager.subscribe
//   POST /api/subscribe         { subscription }
//   POST /api/schedule          { start_min, end_min, rhythm, snooze_min, tz_offset_min }
//   POST /api/day               { action: commit|skip|stop|snooze, end_min?, rhythm? }

import { toMinutes, dueSlot } from './schedule.js';
import { getSettings, getToday, updateToday } from './state.js';

const TICK_MS = 30_000;

// ── server presence (same origin only — KISS) ──

let serverAvailable = null; // null = unknown yet

/**
 * Only `true` is cached. A failed probe (cold start, offline blip, timeout)
 * must not poison the whole session — the next call re-probes. Otherwise a
 * single early failure would silently disable all server features.
 */
export async function hasServer() {
  if (serverAvailable === true) return true;
  try {
    const res = await fetch('/api/health', { signal: AbortSignal.timeout(3000) });
    serverAvailable = res.ok;
  } catch {
    serverAvailable = false;
  }
  return serverAvailable;
}

async function post(path, body) {
  if (!(await hasServer())) return;
  try {
    await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (err) {
    console.warn(`POST ${path} failed`, err);
  }
}

/** Push current settings to the server (call after any settings change). */
export async function syncSchedule() {
  const s = getSettings();
  await post('/api/schedule', {
    start_min: toMinutes(s.startTime),
    end_min: toMinutes(s.endTime),
    rhythm: s.rhythm,
    snooze_min: s.snoozeMin,
    tz_offset_min: -new Date().getTimezoneOffset(),
  });
}

/** Tell the server about a day action so pushes follow suit. */
export async function syncDayAction(action, extra = {}) {
  await post('/api/day', { action, ...extra });
}

// ── permission + push subscription ──

export function permissionState() {
  if (!('Notification' in window)) return 'unsupported';
  return Notification.permission; // 'default' | 'granted' | 'denied'
}

/** Must be called from a user gesture (button tap) — iOS requires it. */
export async function enableNotifications() {
  if (!('Notification' in window)) return 'unsupported';
  const permission = await Notification.requestPermission();
  if (permission === 'granted') {
    await ensurePushRegistered();
  }
  return permission;
}

/**
 * Idempotent push registration: reuse the existing subscription when it is
 * still bound to the server's current VAPID key (subscribePush checks), then
 * POST it and re-sync the schedule. Safe to call on every app start —
 * recovers from a failed first attempt, an expired/rotated subscription, a
 * server-pruned (EndpointNotValid/EndpointNotFound) one, and a server whose
 * VAPID keypair changed (stale subscription → forced re-subscribe).
 * `force` unsubscribes first (used by the settings "Re-register" button).
 */
export async function ensurePushRegistered(force = false) {
  if (permissionState() !== 'granted' || !(await hasServer())) return false;
  if (force) {
    try {
      const reg = await navigator.serviceWorker.ready;
      const existing = await reg.pushManager.getSubscription();
      if (existing) await existing.unsubscribe();
    } catch (err) {
      console.warn('unsubscribe failed (continuing anyway)', err);
    }
  }
  const ok = await subscribePush();
  if (ok) await syncSchedule();
  return ok;
}

async function subscribePush() {
  try {
    const reg = await navigator.serviceWorker.ready;
    let subscription = await reg.pushManager.getSubscription();
    const { key } = await (await fetch('/api/vapid-public-key')).json();
    // Self-heal: if the existing subscription was bound to a DIFFERENT VAPID
    // public key than the server has now (its state volume was recreated, or
    // it moved hosts), Apple rejects every push with 403 VapidPkHashMismatch
    // — and the browser keeps re-POSTing the stale subscription on every
    // launch, so it never recovers on its own. Compare the key the
    // subscription was created with against the server's current key and
    // force a fresh one, instead of relying on the manual Re-register button.
    if (subscription) {
      const bound = subscription.getKey('applicationServerKey');
      if (bound && buf2b64url(new Uint8Array(bound)) !== key) {
        console.warn('subscription bound to a different VAPID key — re-subscribing');
        await subscription.unsubscribe();
        subscription = null;
      }
    }
    if (!subscription) {
      subscription = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(key),
      });
    }
    await post('/api/subscribe', { subscription: subscription.toJSON() });
    return true;
  } catch (err) {
    console.warn('push subscribe failed', err);
    return false;
  }
}

function buf2b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function urlBase64ToUint8Array(base64) {
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const raw = atob(padded.replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

// ── foreground reminders (work without any server, while app is open) ──

/**
 * Starts a 30s ticker. When a slot (or snooze) is due, calls onDue().
 * The caller decides what "notify" means (banner + system notification).
 */
export function startForegroundTicker(onDue) {
  // silent = the user is literally looking at the app right now (just opened /
  // returned to it), so mark the slot as seen without interrupting them.
  const check = (silent) => {
    const today = getToday();
    if (today.skipped || today.stopped) return;

    const now = new Date();
    const nowMin = now.getHours() * 60 + now.getMinutes();

    // Snooze (foreground flavor) fires once, then clears.
    if (today.snoozeUntil && Date.now() >= today.snoozeUntil) {
      updateToday({ snoozeUntil: null });
      if (!silent) onDue();
      return;
    }
    if (today.snoozeUntil) return; // silent while snoozing

    const s = getSettings();
    const end = today.endTime ?? s.endTime;
    const rhythm = today.rhythm ?? s.rhythm;
    const slot = dueSlot(nowMin, toMinutes(s.startTime), toMinutes(end), rhythm, today.lastNotifiedSlot);
    if (slot !== null) {
      updateToday({ lastNotifiedSlot: slot });
      if (!silent) onDue();
    }
  };
  check(true);
  setInterval(() => check(false), TICK_MS);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) check(true);
  });
}

/** Show a system notification if permitted (used for foreground reminders). */
export async function showLocalNotification(title, body) {
  if (permissionState() !== 'granted' || !('serviceWorker' in navigator)) return;
  try {
    const reg = await navigator.serviceWorker.ready;
    await reg.showNotification(title, { body, icon: 'icons/icon-192.png', tag: 'companion' });
  } catch {
    /* some browsers block this outside push context — the in-app banner still shows */
  }
}
