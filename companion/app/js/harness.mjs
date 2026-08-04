// Test harness: boots the real index.html + main.js in jsdom so tests can
// click through the app like a user. Dev-only — the app itself ships no deps.
//
//   npm install --no-save jsdom      (once)
//   node --test app/js/*.test.mjs
//
// Provides a minimal in-memory IndexedDB (only what db.js uses) and stubs for
// the browser APIs jsdom lacks. If db.js starts using more of the IDB API,
// extend fakeIndexedDB below — deliberately small so it stays readable.

import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const APP_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');

// ── tiny in-memory IndexedDB (object store + one index, that's all we need) ──

// One shared instance: db.js caches its connection in a module-level promise,
// and node caches modules across tests in a file. Tests get isolation by
// clearing the rows in bootApp() instead of by swapping the database.
function fakeIndexedDB() {
  const rows = new Map(); // id → record

  const request = (resultFn) => {
    const req = { onsuccess: null, onerror: null, result: undefined };
    queueMicrotask(() => {
      req.result = resultFn();
      req.onsuccess?.();
    });
    return req;
  };

  const matches = (record, query) => {
    if (query === undefined || query === null) return true;
    if (typeof query === 'string') return record.day === query;
    return record.day >= query.lower && record.day <= query.upper; // IDBKeyRange.bound
  };

  const store = {
    add: (record) => request(() => (rows.set(record.id, record), record.id)),
    put: (record) => request(() => (rows.set(record.id, record), record.id)),
    getAll: (query) => request(() => [...rows.values()].filter((r) => matches(r, query))),
    index: () => ({ getAll: (query) => request(() => [...rows.values()].filter((r) => matches(r, query))) }),
    createIndex: () => {},
  };

  const transaction = () => {
    const tx = { objectStore: () => store, oncomplete: null, onerror: null };
    queueMicrotask(() => tx.oncomplete?.());
    return tx;
  };

  return {
    _rows: rows,
    open: () => {
      const req = { onsuccess: null, onerror: null, onupgradeneeded: null, result: null };
      queueMicrotask(() => {
        req.result = { transaction, createObjectStore: () => store, objectStoreNames: { contains: () => true } };
        req.onupgradeneeded?.();
        req.onsuccess?.();
      });
      return req;
    },
  };
}

/**
 * Boot the app. Returns helpers for driving and inspecting it.
 * `search` lets tests simulate e.g. '?from=notification'.
 *
 * Injectable browser bits (defaults keep tests hermetic/offline):
 *   `fetch`               — stub; defaults to throwing 'offline in tests'
 *   `serviceWorker`       — fake navigator.serviceWorker (register/ready/…)
 *   `notificationPermission` — defines window.Notification with this value
 */
const idb = fakeIndexedDB();

export async function bootApp({
  search = '',
  fetch: fetchStub,
  serviceWorker,
  notificationPermission,
} = {}) {
  idb._rows.clear(); // fresh history for every test
  const html = readFileSync(join(APP_DIR, 'index.html'), 'utf8');
  const dom = new JSDOM(html, {
    url: `https://companion.test/${search}`,
    pretendToBeVisual: true,
  });
  const { window } = dom;

  // Browser APIs jsdom doesn't implement — keep stubs minimal and honest.
  window.indexedDB = idb;
  window.IDBKeyRange = { bound: (lower, upper) => ({ lower, upper }) };
  window.crypto.randomUUID ??= () => `id-${Math.random().toString(36).slice(2)}`;
  window.fetch = fetchStub ?? (async () => { throw new Error('offline in tests'); }); // no server by default
  window.scrollTo = () => {};
  Object.defineProperty(window.document, 'hidden', { value: false, configurable: true });
  Object.defineProperty(window.document, 'visibilityState', { value: 'visible', configurable: true });
  if (notificationPermission) {
    Object.defineProperty(window, 'Notification', {
      value: { permission: notificationPermission },
      configurable: true,
    });
  }
  if (serviceWorker) {
    Object.defineProperty(window.navigator, 'serviceWorker', {
      value: serviceWorker,
      configurable: true,
    });
  }

  // Expose globals the modules read at import time. Some (crypto, location,
  // navigator) are getter-only on globalThis, hence defineProperty.
  const globals = ['window', 'document', 'localStorage', 'indexedDB', 'IDBKeyRange',
    'crypto', 'fetch', 'navigator', 'location', 'history'];
  if (notificationPermission) {
    globals.push('Notification');
  } else {
    delete globalThis.Notification; // don't leak a prior boot's permission
  }
  for (const key of globals) {
    Object.defineProperty(globalThis, key, { value: window[key], configurable: true, writable: true });
  }

  // Fresh module instances per test (cache-busting query on the entry point).
  const mainUrl = `${pathToFileURL(join(APP_DIR, 'js', 'main.js')).href}?t=${Math.random()}`;
  await import(mainUrl);
  await tick();

  const $ = (sel) => window.document.querySelector(sel);
  const $$ = (sel) => [...window.document.querySelectorAll(sel)];

  return {
    window,
    document: window.document,
    idb,
    $, $$,
    /** ids of currently visible screens — should always be exactly one. */
    visibleScreens: () => $$('body > section').filter((s) => !s.hidden).map((s) => s.id),
    /** Click an element (by selector or node) and let handlers settle. */
    async click(target) {
      const node = typeof target === 'string' ? $(target) : target;
      if (!node) throw new Error(`click target not found: ${target}`);
      node.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
      await tick();
    },
    /** Find a button/element by its visible text. */
    byText(sel, text) {
      const node = $$(sel).find((n) => n.textContent.includes(text));
      if (!node) throw new Error(`no ${sel} containing "${text}"`);
      return node;
    },
    async type(sel, value) {
      const node = $(sel);
      node.value = value;
      node.dispatchEvent(new window.Event('input', { bubbles: true }));
      await tick();
    },
    async submit(sel) {
      $(sel).dispatchEvent(new window.Event('submit', { bubbles: true, cancelable: true }));
      await tick();
    },
    /** All stored reflections, newest last. */
    records: () => [...idb._rows.values()].sort((a, b) => a.at.localeCompare(b.at)),
    tick,
  };
}

/** Let promise chains and microtask-based IDB callbacks settle. */
export async function tick(times = 6) {
  for (let i = 0; i < times; i++) await new Promise((r) => setTimeout(r, 0));
}
