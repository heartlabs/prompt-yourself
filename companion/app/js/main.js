// App entry point: wires screens, service worker, notification flows.

import { wireNavButtons, showScreen, toast } from './ui.js';
import { initHome } from './home.js';
import { initReflect, openFromNotification, openPickerFresh } from './reflect.js';
import { initSettings } from './settings.js';
import {
  startForegroundTicker, showLocalNotification, hasServer, syncSchedule, syncDayAction,
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
  navigator.serviceWorker.register('sw.js');
  // Messages from the SW (notification action buttons).
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data === 'snooze') snoozeToday();
    if (event.data === 'stop') {
      updateToday({ stopped: true });
      toast('Quiet until tomorrow');
    }
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

// ── keep the server's schedule fresh (tz changes, travel, reinstalls) ──
hasServer().then((server) => {
  if (server) syncSchedule();
});

// Ensure "today" state exists/rolls over even if nothing else touches it.
getToday();
