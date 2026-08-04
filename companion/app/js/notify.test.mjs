// Unit tests for notify.js — pure enough to run without jsdom (no DOM access
// at module scope; hasServer only touches global fetch).
// Run: node --test app/js/*.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hasServer, syncDayAction } from './notify.js';

test('hasServer: a failed probe must not poison subsequent calls', async () => {
  // Cold start, offline blip, or a slow server → probe fails.
  globalThis.fetch = async () => { throw new Error('server unreachable'); };
  assert.equal(await hasServer(), false);

  // The server comes back (or was just slow) — the next call re-probes.
  globalThis.fetch = async () => ({ ok: true });
  assert.equal(await hasServer(), true, 're-probes after a failure');
  assert.equal(await hasServer(), true, 'only the true result is cached (idempotent)');
});

test('syncDayAction: 2xx is success, a server 5xx is a reported failure', async () => {
  // Regression guard: post() used to ignore res.ok, so a 400/500 was treated
  // as a successful day-action sync and the toasts lied.
  let dayCalls = 0;
  globalThis.fetch = async (url) => {
    if (url === '/api/health') return { ok: true };
    if (url === '/api/day') {
      dayCalls += 1;
      return { ok: dayCalls === 1, status: dayCalls === 1 ? 200 : 500 };
    }
    return { ok: true, status: 204 };
  };
  assert.equal(await syncDayAction('stop'), true, '2xx is success');
  assert.equal(await syncDayAction('stop'), false, '5xx is failure, never a silent success');
  assert.equal(dayCalls, 2);
});
