// Notifications: local foreground reminders (always available) and Web Push
// via the optional Rust server (real background notifications on iOS).
//
// Server contract (see server/src/main.rs):
//   GET  /api/health            → { ok: true }        server present?
//   GET  /api/vapid-public-key  → { key }             for pushManager.subscribe
//   POST /api/subscribe         { subscription }
//   POST /api/schedule          { start_min, end_min, rhythm, snooze_min, tz_offset_min }
//   POST /api/day               { action: commit|skip|stop|snooze, end_min?, rhythm? }

import { toMinutes, dueSlot } from './schedule.js';
import { getSettings, getToday, updateToday } from './state.js';

const TICK_MS = 30_000;

// ── server presence (same origin only — KISS) ──

let serverAvailable = null; // null = unknown yet

export async function hasServer() {
  if (serverAvailable === null) {
    try {
      const res = await fetch('/api/health', { signal: AbortSignal.timeout(3000) });
      serverAvailable = res.ok;
    } catch {
      serverAvailable = false;
    }
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
  if (permission === 'granted' && (await hasServer())) {
    await subscribePush();
    await syncSchedule();
  }
  return permission;
}

async function subscribePush() {
  try {
    const reg = await navigator.serviceWorker.ready;
    const { key } = await (await fetch('/api/vapid-public-key')).json();
    const subscription = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(key),
    });
    await post('/api/subscribe', { subscription: subscription.toJSON() });
    return true;
  } catch (err) {
    console.warn('push subscribe failed', err);
    return false;
  }
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
