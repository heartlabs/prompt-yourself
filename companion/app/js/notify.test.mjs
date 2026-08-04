// Unit tests for notify.js — pure enough to run without jsdom (no DOM access
// at module scope; hasServer only touches global fetch).
// Run: node --test app/js/*.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hasServer } from './notify.js';

test('hasServer: a failed probe must not poison subsequent calls', async () => {
  // Cold start, offline blip, or a slow server → probe fails.
  globalThis.fetch = async () => { throw new Error('server unreachable'); };
  assert.equal(await hasServer(), false);

  // The server comes back (or was just slow) — the next call re-probes.
  globalThis.fetch = async () => ({ ok: true });
  assert.equal(await hasServer(), true, 're-probes after a failure');
  assert.equal(await hasServer(), true, 'only the true result is cached (idempotent)');
});
