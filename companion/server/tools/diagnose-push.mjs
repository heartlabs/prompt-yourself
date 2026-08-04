#!/usr/bin/env node
// Diagnose Companion web-push 403s / BadJwtToken: crafts VAPID pushes with the
// CURRENT server keypair and sends them straight to a subscription endpoint,
// printing Apple's status + body (the reason), which /api/test-push discards.
//
// Usage:
//   1. docker cp companion:/srv/state/companion-state.json .
//      (open the app on the phone first so the subscription is in server state)
//   2. node diagnose-push.mjs companion-state.json
//      (uses .subscriptions[0].endpoint; or pass the endpoint as 2nd arg)
//
// Runs a probe matrix that varies only the JWT claims — same key, same
// endpoint — to isolate exactly what Apple rejects:
//   probe 1  sub=mailto:pocket@localhost   (server default — the suspect)
//   probe 2  sub=https://<your-host>       (https URI form)
//   probe 3  sub=mailto:name@real-domain   (proper email form)
//   probe 4  no iat claim                  (rules out iat handling)
//
// Reason codes:
//   BadJwtToken        → the JWT itself is rejected (likely the sub value)
//   VapidPkHashMismatch→ JWT is fine; subscription was created with a
//                        different public key (keypair rotated)
//   BadDeviceToken/404 → endpoint dead
//   VapidTimestampInvalid → clock skew
//   (201/200)          → endpoint + keypair actually fine
//
// Sends EMPTY (payload-less) pushes — legitimate RFC 8030 messages.

import { readFileSync } from 'node:fs';
import crypto from 'node:crypto';

const statePath = process.argv[2];
const endpointArg = process.argv[3];
if (!statePath) {
  console.error('usage: node diagnose-push.mjs <companion-state.json> [endpoint]');
  process.exit(1);
}

const b64url = (buf) => Buffer.from(buf).toString('base64url');
const state = JSON.parse(readFileSync(statePath, 'utf8'));
const privRaw = Buffer.from(state.vapid_private, 'base64url');
const pubRaw = Buffer.from(state.vapid_public, 'base64url');

if (privRaw.length !== 32 || pubRaw.length !== 65) {
  console.error(`unexpected key sizes: private=${privRaw.length}B public=${pubRaw.length}B (want 32/65)`);
  process.exit(1);
}

// Sanity: the stored public key must be the public half of the stored private
// key. (A torn/edited state file can end up with a mismatched pair.)
const ecdh = crypto.createECDH('prime256v1');
ecdh.setPrivateKey(privRaw);
if (!ecdh.getPublicKey().equals(pubRaw)) {
  console.error('✗ state file keypair is MISMATCHED: vapid_public is not the public key of vapid_private');
  process.exit(1);
}
console.log('✓ stored keypair is self-consistent');

const endpoint = endpointArg ?? state.subscriptions[0]?.endpoint;
if (!endpoint) {
  console.error('no endpoint given and state has no subscriptions — open the app on the phone, then re-copy the state file');
  process.exit(1);
}
console.log(`→ endpoint: ${endpoint}\n`);

const key = crypto.createPrivateKey({
  format: 'jwk',
  key: {
    kty: 'EC', crv: 'P-256',
    d: b64url(privRaw),
    x: b64url(pubRaw.subarray(1, 33)),
    y: b64url(pubRaw.subarray(33, 65)),
  },
});
const pub = state.vapid_public;
const now = Math.floor(Date.now() / 1000);
const aud = new URL(endpoint).origin;

async function probe(label, claims) {
  const header = { typ: 'JWT', alg: 'ES256' };
  const sign = (o) => b64url(JSON.stringify(o));
  const input = `${sign(header)}.${sign(claims)}`;
  const sig = crypto.sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' });
  const jwt = `${input}.${b64url(sig)}`;
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { authorization: `vapid t=${jwt}, k=${pub}`, ttl: '60' },
    signal: AbortSignal.timeout(10_000),
  });
  const body = await res.text();
  console.log(`[${label}] HTTP ${res.status}  ${body || '(empty body)'}`);
  return res.status;
}

const probes = [
  ['1 sub=mailto:pocket@localhost', { aud, exp: now + 43200, iat: now, sub: 'mailto:pocket@localhost' }],
  ['2 sub=https://companion.heartlabs.eu', { aud, exp: now + 43200, iat: now, sub: 'https://companion.heartlabs.eu' }],
  ['3 sub=mailto:companion@heartlabs.eu', { aud, exp: now + 43200, iat: now, sub: 'mailto:companion@heartlabs.eu' }],
  ['4 no iat', { aud, exp: now + 43200, sub: 'mailto:pocket@localhost' }],
];

console.log('claims aud=' + aud + ' exp=+12h\n---');
for (const [label, claims] of probes) await probe(label, claims);
