# AGENTS.md — read me before changing anything

This file is the contract for humans and coding agents working on Companion.
The codebase is deliberately small and boring. **Keep it that way.**

## What this is

A local-first PWA for micro self-reflections (companion to
[prompt-yourself](https://github.com/heartlabs/prompt-yourself)), plus an
optional Rust server whose only job is Web Push. Everything may change —
features can be added or removed — but the principles below should survive.

## Principles (in priority order)

1. **KISS / YAGNI.** No build step, no framework, no npm dependencies in the
   app. If a change needs a bundler, reconsider the change.
2. **Local-first privacy.** Reflection *content* never leaves the device.
   The server may only ever see: push subscription, schedule times, day flags
   (committed/skipped/stopped/snoozed). If a feature needs content on the
   server, that's a product decision for the owner, not a refactor.
3. **The user is never guilt-tripped.** Missed prompts are silently replaced
   (one due slot, never a backlog). Resting is a legitimate goal. Keep this
   tone in all copy.
4. **Semantic HTML, vanilla JS.** Screens are `<section>`s in `index.html`;
   `ui.js showScreen()` swaps them. Dynamic bits are rendered with the `el()`
   helper. No innerHTML with user data (XSS).

## Architecture map

```
app/index.html        all screens as <section>s (one visible at a time)
app/css/style.css     the only stylesheet
app/js/
  main.js             entry point, wiring, ?from=notification handling
  ui.js               showScreen/registerScreen, el(), toast
  db.js               IndexedDB — the ONLY module touching the reflections DB
  state.js            localStorage — settings, today-flags, feelings, recent notes
  schedule.js         PURE schedule math (tested; no DOM/storage imports)
  markdown.js         reflection → markdown (stable output format!)
  notify.js           foreground ticker + push subscription + server sync
  home.js             calendar + timeline + detail screens
  reflect.js          commitment → picker → the three reflections
  settings.js         settings screen incl. export/import
app/sw.js             offline cache + push display + notification actions
server/src/main.rs    entire server: state file, HTTP API, tick loop
```

## Contracts that must stay in sync

Changing any of these means changing **both** sides — grep before editing:

| Contract | Client | Server |
|---|---|---|
| Rhythm keys `30min\|hourly\|2h\|3x\|1x` | `schedule.js RHYTHMS` | `slot_times()` |
| Slot math (same algorithm twice) | `schedule.js slotTimes` | `slot_times()` |
| HTTP API (`/api/*`) | `notify.js` header comment | route handlers |
| Push payload `{title, body, first}` | `sw.js` push handler | `send_push()` |
| Reflection record shape | `db.js` header comment | — (never sent) |
| Markdown format | `markdown.js` | — users paste it into their vaults: treat as a public API, change only deliberately |

## Reflection record shape

```js
{ id: uuid, type: 'energy'|'questions'|'feelings', at: ISO-8601,
  day: 'YYYY-MM-DD' /* local date, denormalized for the day index */,
  data: {
    // energy:    { level: 'green'|'yellow'|'red', note: string }
    // questions: { doing, goal, progressing, feeling, next }  (strings, may be '')
    // feelings:  { values: { [name: string]: 0..100 } }
  } }
```

Adding a reflection type = add a section in `index.html`, an entry in
`reflect.js REFLECTIONS`, cases in `markdown.js` + `home.js summaryLine/renderDetail`.
Nothing else should need to change.

## Gotchas a future agent WILL trip over

- **Never let author CSS set `display` on something that toggles `hidden`.**
  `style.css` starts with `[hidden] { display: none !important; }` — do not
  remove it. Without it, `body > section { display: flex }` beats the browser's
  built-in `[hidden]` rule, every screen renders stacked at once, and the app
  looks completely dead (clicks "do nothing"). This has already happened once.
  The test `home shows exactly one screen` guards it.
- **Bump `VERSION` in `app/js/version.js` on every app change** (it busts the
  SW cache and is shown in the Settings footer), or installed PWAs keep
  serving stale cached files. This is the #1 "my change does nothing" trap.
- Starting a reflection by hand uses `#start-reflection` → `openPickerFresh()`,
  deliberately *not* `data-nav` — a new session must un-dim finished items.
- iOS Web Push only works: HTTPS + installed to Home Screen + permission
  requested from a user gesture. Nothing to debug in code if one is missing.
- `notification.tag = 'companion'` makes new pushes replace old ones — that's
  the no-backlog rule, don't remove it.
- The energy flow saves **on tap** (screen-energy) and then *updates* the same
  record with the note (via `importAll` put-overwrite). Don't turn the note
  into a second record.
- Feelings sliders persist to localStorage *while sliding*; the reflection
  snapshot is only written on "Save snapshot". Two different stores, on purpose.
- `today` state in localStorage auto-resets when the date changes
  (`state.js getToday`). Server has the same logic in `tick()`.
- Times are minutes-since-local-midnight everywhere; the client sends its UTC
  offset (`tz_offset_min`) so the single-user server can think in local time.
- Test command is `node --test app/js/*.test.mjs` (pattern matters — plain
  `node --test app/js/` tries to run non-test files).

## Planned evolution (context for decisions)

- **HTMX migration:** once the Rust backend grows real endpoints, screens
  should become server-rendered fragments swapped by HTMX. That's why screens
  are self-contained `<section>`s with plain forms — keep new UI in that
  shape (hypermedia-friendly, minimal client state).
- Possible later: real journal sync into Obsidian (today: copy-as-markdown),
  multi-device sync, richer reflection library. None of that justifies extra
  complexity *now*.

## Testing

```sh
npm install --no-save jsdom                    # once, dev-only
node --test --test-force-exit app/js/*.test.mjs
```

- `flow.test.mjs` boots the **real** `index.html` + `main.js` in jsdom
  (`harness.mjs`) and clicks through actual user journeys. Add a case for every
  new screen or flow — this is what catches "the app is dead" bugs that pure
  unit tests miss.
- `--test-force-exit` is required: the app installs a `setInterval` ticker that
  keeps node alive.
- `harness.mjs` ships a deliberately tiny in-memory IndexedDB (only what
  `db.js` uses). Extend it if `db.js` grows; don't add npm deps for it.
- jsdom is dev-only. **The app itself must stay dependency-free and buildless.**
- Pure logic: `schedule.test.mjs`. Keep DOM code out of `schedule.js` /
  `markdown.js` so they stay trivially node-testable.
- Server: `cd server && cargo build` must pass warning-free-ish; manual smoke:
  run it, `curl localhost:8990/api/health`.
- Manual device check after UI changes: iPhone Safari, installed to Home
  Screen (the standalone-mode viewport and safe-area behave differently from
  the browser tab).
