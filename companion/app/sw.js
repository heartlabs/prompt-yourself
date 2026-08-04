// Service worker: offline app shell + Web Push display + notification actions.
// VERSION lives in js/version.js (shared with the settings footer) — bump it
// there on every app change, it busts this cache.

import { VERSION } from './js/version.js';

const CACHE = `companion-${VERSION}`;
const SHELL = [
  './',
  'index.html',
  'css/style.css',
  'js/main.js', 'js/ui.js', 'js/db.js', 'js/state.js', 'js/schedule.js',
  'js/markdown.js', 'js/notify.js', 'js/home.js', 'js/reflect.js', 'js/settings.js',
  'js/version.js',
  'manifest.webmanifest',
  'icons/icon-192.png', 'icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Cache-first for the shell; network for everything else (e.g. /api/*).
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== location.origin || url.pathname.includes('/api/')) return;
  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((hit) => hit ?? fetch(event.request))
  );
});

// ── Web Push (sent by the Rust server) ──

function urlBase64ToUint8Array(base64) {
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const raw = atob(padded.replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

// The browser can silently rotate a subscription (new endpoint/keys).
// Re-subscribe and re-POST, or pushes die without any user-visible error.
self.addEventListener('pushsubscriptionchange', (event) => {
  const refresh = async () => {
    const { key } = await (await fetch('/api/vapid-public-key')).json();
    const subscription = await self.registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(key),
    });
    return fetch('/api/subscribe', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ subscription: subscription.toJSON() }),
    });
  };
  event.waitUntil(refresh().catch(() => {}));
});

self.addEventListener('push', (event) => {
  let data = { title: 'Companion', body: 'Time for a check-in.' };
  try { data = { ...data, ...event.data.json() }; } catch { /* keep defaults */ }
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: 'icons/icon-192.png',
      badge: 'icons/icon-192.png',
      tag: 'companion', // replaces earlier notifications — no pile-up
      data,
      actions: [
        { action: 'snooze', title: 'Snooze' },
        { action: 'stop', title: 'Stop for today' },
      ],
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const action = event.action;

  if (action === 'snooze' || action === 'stop') {
    // Tell the server directly (works even when the page isn't open) …
    event.waitUntil(
      fetch('/api/day', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action }),
      }).catch(() => {})
        // … and any open page, so foreground state stays in sync.
        .then(() => self.clients.matchAll({ type: 'window' }))
        .then((clients) => clients.forEach((c) => c.postMessage(action)))
    );
    return;
  }

  // Default tap → open the app in "arrived from notification" mode.
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      const existing = clients.find((c) => 'focus' in c);
      if (existing) {
        existing.navigate('./?from=notification');
        return existing.focus();
      }
      return self.clients.openWindow('./?from=notification');
    })
  );
});
