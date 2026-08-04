// App entry point: wires screens, service worker, notification flows.

import { wireNavButtons, showScreen, toast } from './ui.js';
import { initHome } from './home.js';
import { initReflect, openFromNotification, openPickerFresh } from './reflect.js';
import { initSettings } from './settings.js';
import {
  startForegroundTicker, showLocalNotification, hasServer, syncSchedule, syncDayAction,
  ensurePushRegistered,
} from './notify.js';
import { getToday, updateToday, getSettings } from './state.js';

initHome();
initReflect();
initSettings();
wireNavButtons();

// Starting a reflection by hand begins a new picker session (nothing dimmed).
document.getElementById('start-reflection').addEventListener('click', openPickerFresh);

// ── service worker ──
if ('serviceWorker' in navigator) {
  // updateViaCache: 'none' — WebKit may otherwise serve sw.js (and its
  // imported js/version.js) from the HTTP cache, which is exactly how a PWA
  // gets stuck on an old build. nginx.conf also forces no-cache on /sw.js.
  navigator.serviceWorker.register('sw.js', { type: 'module', updateViaCache: 'none' });
  // Messages from the SW (notification action buttons).
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data === 'snooze') snoozeToday();
    if (event.data === 'stop') {
      updateToday({ stopped: true });
      toast('Quiet until tomorrow');
    }
  });
  // A newly installed SW (new VERSION deployed) takes over via skipWaiting +
  // clients.claim — reload once so this page actually runs the new build
  // instead of showing the old version until the next launch.
  let refreshed = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (refreshed) return;
    refreshed = true;
    location.reload();
  });

  // iOS is lazy about SW updates: standalone PWAs can sit on a stale build
  // for days, and restoring from bfcache doesn't fire a load at all. Nudge an
  // explicit update check whenever the app returns to the foreground.
  const checkForUpdate = () => {
    navigator.serviceWorker.ready
      .then((reg) => reg.update())
      .catch((err) => console.warn('SW update check failed', err));
  };
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') checkForUpdate();
  });
  window.addEventListener('pageshow', (e) => {
    if (e.persisted) checkForUpdate(); // restored from bfcache — no load event
  });
}

function snoozeToday() {
  const min = getSettings().snoozeMin;
  updateToday({ snoozeUntil: Date.now() + min * 60_000 });
  syncDayAction('snooze');
  toast(`Snoozed ${min} min`);
}

// ── entry: from a notification / Shortcuts automation, or normal open ──
const params = new URLSearchParams(location.search);
if (params.get('from') === 'notification') {
  history.replaceState(null, '', location.pathname); // don't re-trigger on reload
  openFromNotification();
} else {
  showScreen('screen-home');
}

// ── foreground reminders (no server needed, app must be open) ──
startForegroundTicker(() => {
  showLocalNotification('Time for a check-in', 'A quiet minute with yourself.');
  // If the user is sitting on the home screen, bring up the flow directly.
  if (!document.getElementById('screen-home').hidden && !document.hidden) {
    openFromNotification();
  }
});

// ── keep the server's schedule + push registration fresh ──
// Re-runs every cold start: re-syncs the schedule (tz changes, travel,
// reinstalls) and re-registers the push subscription if it is missing,
// expired, rotated, or was pruned by the server. No-ops when the server is
// down or permission isn't granted yet.
hasServer().then((server) => {
  if (!server) return;
  syncSchedule();
  ensurePushRegistered();
});

// Ensure "today" state exists/rolls over even if nothing else touches it.
getToday();
