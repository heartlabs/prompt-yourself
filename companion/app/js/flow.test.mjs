// End-to-end user journeys, driven through the real DOM in jsdom.
// Requires: npm install --no-save jsdom
// Run:      node --test app/js/*.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bootApp } from './harness.mjs';


test('home shows exactly one screen (regression: [hidden] must hide)', async () => {
  const app = await bootApp();
  assert.deepEqual(app.visibleScreens(), ['screen-home']);
  // The calendar actually rendered.
  assert.ok(app.$$('#cal-grid .d').length >= 28, 'calendar has day cells');
  assert.ok(app.$('#cal-title').textContent.match(/\d{4}/), 'month title has a year');
});

test('FAB opens the picker with all three reflections', async () => {
  const app = await bootApp();
  await app.click('.fab');
  assert.deepEqual(app.visibleScreens(), ['screen-picker']);
  assert.equal(app.$$('#picker-options .opt').length, 3);
});

test('energy: one tap saves, note enriches the SAME record', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Energy'));
  assert.deepEqual(app.visibleScreens(), ['screen-energy']);

  await app.click('.light.yellow');
  assert.deepEqual(app.visibleScreens(), ['screen-energy-note']);
  assert.equal(app.records().length, 1, 'saved immediately on tap');
  assert.equal(app.records()[0].data.level, 'yellow');

  await app.type('#note-text', 'slow start, short night');
  await app.click('#note-done');
  assert.equal(app.records().length, 1, 'note must not create a second record');
  assert.equal(app.records()[0].data.note, 'slow start, short night');

  // Back at the picker, energy dimmed, and the note is offered as a chip later.
  assert.deepEqual(app.visibleScreens(), ['screen-picker']);
  assert.ok(app.byText('.opt', 'Energy').classList.contains('done'));
});

test('energy: skipping the note keeps the record noteless', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Energy'));
  await app.click('.light.green');
  await app.click('#note-skip');
  assert.equal(app.records().length, 1);
  assert.equal(app.records()[0].data.note, '');
});

test('energy: recent notes appear as one-tap chips next time', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Energy'));
  await app.click('.light.red');
  await app.type('#note-text', 'meeting drained me');
  await app.click('#note-done');

  await app.click(app.byText('.opt', 'Energy'));
  await app.click('.light.yellow');
  const chips = app.$$('#note-chips .chip').map((c) => c.textContent);
  assert.ok(chips.includes('meeting drained me'), `chips were ${JSON.stringify(chips)}`);

  await app.click(app.byText('#note-chips .chip', 'meeting drained me'));
  assert.equal(app.$('#note-text').value, 'meeting drained me');
});

test('5 questions: traffic light → sliders → one combined record', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));

  // The big flow starts on the traffic light, and there is NO note screen.
  assert.deepEqual(app.visibleScreens(), ['screen-energy']);
  assert.equal(app.$('#energy-hint').hidden, false, 'flow hint is visible');
  await app.click('.light.yellow');
  assert.deepEqual(app.visibleScreens(), ['screen-questions'], 'straight to the questions, no note');

  // Feelings sliders come from the shared store; add one.
  await app.type('#q-feeling-add', 'tired');
  await app.click('#q-feeling-add-btn');
  assert.equal(app.$$('#q-feelings-list .feel').length, 1);

  await app.type('[name="goal"]', 'relaxing');
  await app.type('[name="doing"]', 'sitting on the balcony');
  await app.submit('#questions-form');

  assert.equal(app.records().length, 1, 'one combined record, nothing orphaned');
  const saved = app.records()[0];
  assert.equal(saved.type, 'questions');
  assert.equal(saved.data.doing, 'sitting on the balcony');
  assert.equal(saved.data.goal, 'relaxing');
  assert.equal(saved.data.energy, 'yellow', 'the tapped light lives in the record');
  assert.deepEqual(saved.data.values, { tired: 50 }, 'feelings snapshot lives in the record');
  assert.deepEqual(app.visibleScreens(), ['screen-picker']);
});

test('5 questions: empty form is refused', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green');
  await app.type('#q-feeling-add', 'tired');
  await app.click('#q-feeling-add-btn');
  await app.submit('#questions-form');
  assert.equal(app.records().length, 0);
  assert.deepEqual(app.visibleScreens(), ['screen-questions'], 'stays put');
});

test('5 questions: feelings are mandatory (like the standalone screen)', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green');
  await app.type('[name="doing"]', 'writing');
  await app.submit('#questions-form');
  assert.equal(app.records().length, 0);
  assert.match(app.$('#toast').textContent, /Add a feeling first/);
  assert.deepEqual(app.visibleScreens(), ['screen-questions'], 'stays put');
});

test('5 questions: progressing always shows the fixed quick-answer chips', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green');

  const chips = app.$$('#chips-progressing .chip').map((c) => c.textContent);
  assert.deepEqual(chips, ['sure', 'probably', 'maybe', 'not really', 'no']);

  await app.click(app.byText('#chips-progressing .chip', 'not really'));
  assert.equal(app.$('[name="progressing"]').value, 'not really');
});

test('5 questions: past answers become chips for doing, goal and next', async () => {
  const app = await bootApp();

  // Fresh install: no history yet → the dynamic chip rows are hidden.
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green');
  assert.equal(app.$('#chips-doing').hidden, true, 'doing row hidden without history');
  assert.equal(app.$('#chips-goal').hidden, true);

  // Save a reflection with real answers.
  await app.type('#q-feeling-add', 'tired');
  await app.click('#q-feeling-add-btn');
  await app.type('[name="doing"]', 'sitting on the balcony');
  await app.type('[name="goal"]', 'relaxing');
  await app.type('[name="next"]', 'keep going');
  await app.submit('#questions-form');

  // Re-enter: each question offers its own past answer as a chip.
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green');
  assert.equal(app.$('#chips-doing').hidden, false, 'doing row appears once there is history');
  assert.equal(app.byText('#chips-doing .chip', 'sitting on the balcony').textContent, 'sitting on the balcony');
  assert.equal(app.byText('#chips-goal .chip', 'relaxing').textContent, 'relaxing');
  assert.equal(app.byText('#chips-next .chip', 'keep going').textContent, 'keep going');

  // Tapping a chip fills that question's box.
  await app.click(app.byText('#chips-doing .chip', 'sitting on the balcony'));
  assert.equal(app.$('[name="doing"]').value, 'sitting on the balcony');
});

test('5 questions: Back returns to the traffic light; re-tap changes the energy', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green');
  await app.click('#questions-back');
  assert.deepEqual(app.visibleScreens(), ['screen-energy']);
  assert.ok(app.$('.light.green').classList.contains('sel'), 'picked light is highlighted');
  await app.click('.light.red');
  assert.deepEqual(app.visibleScreens(), ['screen-questions']);
  await app.type('#q-feeling-add', 'tired');
  await app.click('#q-feeling-add-btn');
  await app.type('[name="doing"]', 'working');
  await app.submit('#questions-form');
  assert.equal(app.records()[0].data.energy, 'red', 're-tap replaced the energy');
});

test('5 questions: feelings sliders share the exact state with the standalone screen', async () => {
  const app = await bootApp();

  // Set up state via the standalone feelings screen (add + slide).
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Feelings'));
  await app.type('#feeling-add', 'calm');
  await app.click('#feeling-add-form button[type="submit"]');
  const slider = app.$$('#feelings-list input[type="range"]')[0];
  slider.value = '64';
  slider.dispatchEvent(new app.window.Event('input', { bubbles: true }));

  // The 5 Questions flow loads the exact same list + values.
  await app.click('#screen-feelings .backbtn');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green');
  assert.equal(app.$$('#q-feelings-list .feel').length, 1);
  assert.equal(app.$('#q-feelings-list .feel b').textContent, 'calm');
  assert.equal(app.$$('#q-feelings-list input[type="range"]')[0].value, '64', 'same slider state');

  // Removal in the questions flow propagates back.
  await app.click(app.$$('#q-feelings-list .x')[0]);
  await app.click('#questions-back');
  await app.click('#screen-energy .backbtn');
  await app.click(app.byText('.opt', 'Feelings'));
  assert.equal(app.$$('#feelings-list .feel').length, 0, 'removal propagated to the standalone screen');
});

test('home: the combined 5 Questions record tints the dot and opens in detail', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.yellow');
  await app.type('#q-feeling-add', 'tired');
  await app.click('#q-feeling-add-btn');
  const slider = app.$$('#q-feelings-list input[type="range"]')[0];
  slider.value = '72';
  slider.dispatchEvent(new app.window.Event('input', { bubbles: true }));
  await app.type('[name="doing"]', 'coding');
  await app.submit('#questions-form');

  await app.click(app.byText('.btn.quiet', 'Back to home'));
  assert.equal(app.$$('#cal-grid .d.yellow').length, 1, 'dot tinted by energy inside the record');

  await app.click('#day-timeline .row');
  const text = app.$('#detail-body').textContent;
  assert.match(text, /Energy/);
  assert.match(text, /yellow/);
  assert.match(text, /tired/);
  assert.match(text, /72\/100/);
});

test('detail: legacy 5 Questions records (text feeling, no energy) still render', async () => {
  const app = await bootApp();
  const now = new Date();
  const day = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  app.idb._rows.set('legacy-1', {
    id: 'legacy-1', type: 'questions', at: now.toISOString(), day,
    data: { doing: 'walking', feeling: 'peaceful', next: 'stay outside' },
  });
  await app.click('.fab'); // leave home and come back so the timeline re-renders
  await app.click(app.byText('.btn.quiet', 'Back to home'));
  await app.click('#day-timeline .row');
  const text = app.$('#detail-body').textContent;
  assert.match(text, /Feeling/);
  assert.match(text, /peaceful/);
});

test('feelings: add, slide, snapshot; sliders persist to the next session', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Feelings'));

  await app.type('#feeling-add', 'tired');
  await app.submit('#feeling-add-form');
  await app.type('#feeling-add', 'excited');
  await app.submit('#feeling-add-form');
  assert.equal(app.$$('#feelings-list .feel').length, 2);

  const slider = app.$$('#feelings-list input[type="range"]')[0];
  slider.value = '72';
  slider.dispatchEvent(new app.window.Event('input', { bubbles: true }));

  await app.click('#feelings-save');
  const saved = app.records().at(-1);
  assert.equal(saved.type, 'feelings');
  assert.deepEqual(saved.data.values, { tired: 72, excited: 50 });

  // Re-open: sliders keep their positions.
  await app.click(app.byText('.opt', 'Feelings'));
  assert.equal(app.$$('#feelings-list input[type="range"]')[0].value, '72');

  // Remove one.
  await app.click(app.$$('#feelings-list .x')[0]);
  assert.equal(app.$$('#feelings-list .feel').length, 1);
});

test('feelings: a fresh (empty) list has a visible Add button', async () => {
  // Regression guard: on a fresh install there are no feelings, so the input
  // alone was a dead-end — Enter is invisible. The Add button must be in the
  // DOM and work without the keyboard.
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Feelings'));
  assert.equal(app.$$('#feelings-list .feel').length, 0, 'starts empty');

  const addBtn = app.$('#feeling-add-form button[type="submit"]');
  assert.ok(addBtn, 'Add button exists');
  assert.equal(addBtn.textContent, 'Add');

  await app.type('#feeling-add', 'anxious');
  await app.click(addBtn); // no Enter needed
  assert.equal(app.$$('#feelings-list .feel').length, 1);
  assert.equal(app.$('#feelings-list .feel b').textContent, 'anxious');
});

test('feelings: saving with no feelings is refused', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Feelings'));
  await app.click('#feelings-save');
  assert.equal(app.records().length, 0);
});

test('?from=notification opens the daily commitment, then the picker', async () => {
  const app = await bootApp({ search: '?from=notification' });
  assert.deepEqual(app.visibleScreens(), ['screen-commit']);

  app.$('#commit-end').value = '17:00';
  app.$('#commit-rhythm').value = '3x';
  await app.click('#commit-yes');
  assert.deepEqual(app.visibleScreens(), ['screen-picker']);

  const today = JSON.parse(app.window.localStorage.getItem('today'));
  assert.equal(today.committed, true);
  assert.equal(today.endTime, '17:00');
  assert.equal(today.rhythm, '3x');
});

test('skipping the day is recorded and returns home', async () => {
  const app = await bootApp({ search: '?from=notification' });
  await app.click('#commit-skip');
  assert.deepEqual(app.visibleScreens(), ['screen-home']);
  assert.equal(JSON.parse(app.window.localStorage.getItem('today')).skipped, true);
});

test('a committed day goes straight to the picker', async () => {
  const app = await bootApp({ search: '?from=notification' });
  await app.click('#commit-yes');
  // Simulate a later notification tap in the same session.
  await app.click('.fab');
  assert.deepEqual(app.visibleScreens(), ['screen-picker']);
});

test('calendar: today gets a dot, tapping through reaches the detail', async () => {
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Energy'));
  await app.click('.light.green');
  await app.click('#note-skip');
  await app.click(app.byText('.btn.quiet', 'Back to home'));

  assert.deepEqual(app.visibleScreens(), ['screen-home']);
  assert.equal(app.$$('#cal-grid .d.green').length, 1, 'today tinted by energy level');
  assert.equal(app.$$('#day-timeline .row').length, 1, "today's timeline shows it");

  await app.click('#day-timeline .row');
  assert.deepEqual(app.visibleScreens(), ['screen-detail']);
  assert.match(app.$('#detail-body').textContent, /Energy/);
});

test('settings: window, rhythm and snooze persist', async () => {
  const app = await bootApp();
  await app.click('[data-nav="screen-settings"]');
  assert.deepEqual(app.visibleScreens(), ['screen-settings']);

  const end = app.$('#set-end');
  end.value = '20:00';
  end.dispatchEvent(new app.window.Event('change', { bubbles: true }));
  await app.click(app.byText('#set-rhythm button', '3×/day'));
  await app.click(app.byText('#set-snooze button', '30 min'));

  const settings = JSON.parse(app.window.localStorage.getItem('settings'));
  assert.equal(settings.endTime, '20:00');
  assert.equal(settings.rhythm, '3x');
  assert.equal(settings.snoozeMin, 30);
  assert.ok(app.byText('#set-rhythm button', '3×/day').classList.contains('on'));
});

test('settings: stop for today silences and goes home', async () => {
  const app = await bootApp();
  await app.click('[data-nav="screen-settings"]');
  await app.click('#stop-today');
  assert.deepEqual(app.visibleScreens(), ['screen-home']);
  assert.equal(JSON.parse(app.window.localStorage.getItem('today')).stopped, true);
});

test('settings: footer shows the app version (update check)', async () => {
  const app = await bootApp();
  await app.click('[data-nav="screen-settings"]');
  assert.match(app.$('#app-version').textContent, /^Companion v\d+$/);
});

test('returning to the foreground triggers an SW update check', async () => {
  // Regression guard: iOS is lazy about SW updates; the app must nudge
  // registration.update() when it becomes visible again.
  let updates = 0;
  const serviceWorker = {
    register: async () => {},
    addEventListener: () => {},
    ready: Promise.resolve({ update: () => { updates++; } }),
  };
  const app = await bootApp({ serviceWorker });
  app.document.dispatchEvent(new app.window.Event('visibilitychange'));
  await app.tick();
  assert.equal(updates, 1, 'visibilitychange → visible must call registration.update()');
});

test('settings: test + re-register buttons are always visible (recovery UI)', async () => {
  // Regression guard for "no way to recover from a silently failed
  // registration": once permission is granted, notif-enable disappears, so
  // these two must always be there (even offline).
  const app = await bootApp();
  await app.click('[data-nav="screen-settings"]');
  assert.deepEqual(app.visibleScreens(), ['screen-settings']);
  assert.equal(app.$('#notif-test').hidden, false);
  assert.equal(app.$('#notif-reregister').hidden, false);
});

test('boot with permission granted + reachable server registers the push subscription', async () => {
  // The phone that granted permission but never registered (or whose
  // subscription was later rotated/pruned) must self-heal on next launch.
  const calls = [];
  const fetchStub = async (url, opts = {}) => {
    calls.push({ url, method: opts.method ?? 'GET' });
    if (url === '/api/health') return { ok: true };
    if (url === '/api/vapid-public-key') {
      return { ok: true, json: async () => ({ key: 'fake-key' }) };
    }
    if (url === '/api/status') {
      return { ok: true, json: async () => ({ subscriptions: 1 }) };
    }
    return { ok: true, status: 204 };
  };
  const serviceWorker = {
    register: async () => {},
    addEventListener: () => {},
    ready: Promise.resolve({
      pushManager: {
        getSubscription: async () => null,
        subscribe: async () => ({
          toJSON: () => ({
            endpoint: 'https://push.example/sub',
            keys: { p256dh: 'k', auth: 'a' },
          }),
        }),
      },
    }),
  };
  const app = await bootApp({
    fetch: fetchStub,
    serviceWorker,
    notificationPermission: 'granted',
  });

  // The boot-time ensurePushRegistered() chain is async; wait for the POST.
  await waitFor(() => calls.some((c) => c.url === '/api/subscribe' && c.method === 'POST'));
  assert.ok(
    calls.some((c) => c.url === '/api/subscribe' && c.method === 'POST'),
    'must POST the subscription to /api/subscribe on start'
  );
  assert.ok(
    calls.some((c) => c.url === '/api/schedule' && c.method === 'POST'),
    'must re-sync the schedule too'
  );
});

test('boot with a subscription bound to a stale VAPID key self-heals (re-subscribe)', async () => {
  // Regression guard for the stale-subscription loop: if the server's VAPID
  // keypair changed (e.g. state volume recreated), the browser still holds a
  // subscription bound to the OLD key — every push 403s (VapidPkHashMismatch)
  // and the app would otherwise re-POST the dead one forever. subscribePush()
  // must detect the mismatch, unsubscribe, and register a fresh subscription.
  const calls = [];
  let staleUnsubscribed = 0;
  let freshSubscribes = 0;
  const fetchStub = async (url, opts = {}) => {
    calls.push({ url, method: opts.method ?? 'GET', body: opts.body });
    if (url === '/api/health') return { ok: true };
    if (url === '/api/vapid-public-key') {
      return { ok: true, json: async () => ({ key: 'current-server-key' }) };
    }
    if (url === '/api/status') {
      return { ok: true, json: async () => ({ subscriptions: 1 }) };
    }
    return { ok: true, status: 204 };
  };
  const staleSub = {
    getKey: () => Uint8Array.from([1, 2, 3]).buffer, // bound to an OLD key
    unsubscribe: async () => { staleUnsubscribed += 1; },
    toJSON: () => ({ endpoint: 'https://push.example/stale', keys: {} }),
  };
  const serviceWorker = {
    register: async () => {},
    addEventListener: () => {},
    ready: Promise.resolve({
      pushManager: {
        getSubscription: async () => staleSub,
        subscribe: async () => {
          freshSubscribes += 1;
          return {
            toJSON: () => ({ endpoint: 'https://push.example/fresh', keys: { p256dh: 'k', auth: 'a' } }),
          };
        },
      },
    }),
  };
  const app = await bootApp({ fetch: fetchStub, serviceWorker, notificationPermission: 'granted' });

  await waitFor(() => calls.some((c) => c.url === '/api/subscribe' && c.method === 'POST'));
  const posted = calls.find((c) => c.url === '/api/subscribe' && c.method === 'POST');
  assert.equal(staleUnsubscribed, 1, 'stale subscription must be unsubscribed');
  assert.equal(freshSubscribes, 1, 'a fresh subscription must be created');
  assert.equal(
    JSON.parse(posted.body).subscription.endpoint,
    'https://push.example/fresh',
    'must POST the fresh subscription, not the stale one'
  );
});

/** Poll until `predicate` is true (bounded), for async boot chains. */
function waitFor(predicate, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    (function poll() {
      if (predicate()) return resolve();
      if (Date.now() - start > timeoutMs) return reject(new Error('waitFor timed out'));
      setTimeout(poll, 5);
    })();
  });
}

test('back buttons return to the expected screens', async () => {
  const app = await bootApp();
  await app.click('[data-nav="screen-settings"]');
  await app.click('#screen-settings .backbtn');
  assert.deepEqual(app.visibleScreens(), ['screen-home']);

  await app.click('.fab');
  await app.click(app.byText('.opt', 'Energy'));
  await app.click('#screen-energy .backbtn');
  assert.deepEqual(app.visibleScreens(), ['screen-picker']);
});

// ── silent-failure guards (SILENT-FAILURES-PLAN.md) ──

test('broken localStorage: commit still opens the picker and says it won\'t persist', async () => {
  const app = await bootApp({ search: '?from=notification', storageFail: true });
  await app.click('#commit-yes');
  assert.deepEqual(app.visibleScreens(), ['screen-picker'], 'picker still opens');
  assert.match(app.$('#toast').textContent, /Couldn't save/, 'user is told the commit did not persist');
});

test('full storage: energy tap stays on the lights and says nothing saved', async () => {
  const app = await bootApp({ idbFail: true });
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Energy'));
  await app.click('.light.green');
  assert.deepEqual(app.visibleScreens(), ['screen-energy'], 'stays on the lights');
  assert.match(app.$('#toast').textContent, /Couldn't save/);
  assert.equal(app.records().length, 0, 'nothing was written');
});

test('full storage: 5 questions keep your answers on screen', async () => {
  const app = await bootApp({ idbFail: true });
  await app.click('.fab');
  await app.click(app.byText('.opt', '5 Questions'));
  await app.click('.light.green'); // held, not saved — nothing can fail yet
  await app.type('#q-feeling-add', 'tired');
  await app.click('#q-feeling-add-btn');
  await app.type('[name="doing"]', 'sitting on the balcony');
  await app.submit('#questions-form');
  assert.deepEqual(app.visibleScreens(), ['screen-questions'], 'does not advance');
  assert.match(app.$('#toast').textContent, /Couldn't save/);
  assert.equal(app.$('[name="doing"]').value, 'sitting on the balcony', 'answers not wiped');
  assert.equal(app.records().length, 0, 'nothing was written');
});

test('full storage: the energy note cannot be enriched, note is kept on screen', async () => {
  // The tap itself succeeds only if the DB is writable; to hit the note-enrich
  // failure we need the FIRST write to succeed and the second (importAll) to
  // fail — not expressible with a static idbFail, so simulate storage filling
  // up between the two writes.
  const app = await bootApp();
  await app.click('.fab');
  await app.click(app.byText('.opt', 'Energy'));
  await app.click('.light.green'); // saved fine
  app.idb._state.failWrites = true; // storage now "full"
  await app.type('#note-text', 'a note that cannot be saved');
  await app.click('#note-done');
  assert.deepEqual(app.visibleScreens(), ['screen-energy-note'], 'stays on the note screen');
  assert.match(app.$('#toast').textContent, /Couldn't save/);
  assert.equal(app.$('#note-text').value, 'a note that cannot be saved', 'note text not wiped');
  assert.equal(app.records().length, 1, 'the energy record itself is intact');
});

test('stop for today is honest when the server is unreachable', async () => {
  const app = await bootApp(); // default fetch → 'offline in tests'
  await app.click('[data-nav="screen-settings"]');
  await app.click('#stop-today');
  assert.deepEqual(app.visibleScreens(), ['screen-home']);
  assert.match(app.$('#toast').textContent, /couldn't reach the server/);
  assert.equal(JSON.parse(app.window.localStorage.getItem('today')).stopped, true, 'locally quiet regardless');
});

test('enable notifications tells the truth when registration fails', async () => {
  // Server up (health/vapid/status fine) but the subscription POST is rejected
  // — the old code toasted "Notifications on" anyway.
  // A REAL 65-byte base64url VAPID key: with a fake one ('k') the app crashes
  // in atob() before the POST is ever made, so the test would exercise the
  // wrong failure path. This one decodes cleanly, so the failure is the 500.
  const VAPID_PUBLIC_KEY = Buffer.from(Array.from({ length: 65 }, (_, i) => i))
    .toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const calls = [];
  const fetchStub = async (url, opts = {}) => {
    calls.push({ url, method: opts.method ?? 'GET' });
    if (url === '/api/health') return { ok: true };
    if (url === '/api/vapid-public-key') return { ok: true, json: async () => ({ key: VAPID_PUBLIC_KEY }) };
    if (url === '/api/status') return { ok: true, json: async () => ({ subscriptions: 1 }) };
    if (url === '/api/subscribe') return { ok: false, status: 500 };
    return { ok: true, status: 204 };
  };
  const serviceWorker = {
    register: async () => {},
    addEventListener: () => {},
    ready: Promise.resolve({
      pushManager: {
        getSubscription: async () => null,
        subscribe: async () => ({ toJSON: () => ({ endpoint: 'e', keys: { p256dh: 'k', auth: 'a' } }) }),
      },
    }),
  };
  const app = await bootApp({ fetch: fetchStub, serviceWorker, notificationPermission: 'granted' });
  await app.click('[data-nav="screen-settings"]');
  await app.click('#notif-enable');
  await waitFor(() => /not registered/.test(app.$('#toast').textContent));
  assert.match(app.$('#toast').textContent, /not registered/);
  // Prove the failure was the HTTP 500, not an earlier crash: the subscription
  // POST must actually have been attempted with a decodable key.
  assert.ok(
    calls.some((c) => c.url === '/api/subscribe' && c.method === 'POST'),
    'the subscription POST must be attempted (real base64 key)'
  );
});
