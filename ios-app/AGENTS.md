# iOS App — Agent Guide

Everything in this file stays true no matter how the codebase evolves.
**Architecture specifics are NOT documented here** — they live as header and
doc comments in the code files themselves. Before editing any file, read its
header comment and the doc comments of everything you call. Those comments
are contracts: update them together with the code, in the same commit. A
stale contract comment is worse than none.

When existing code contradicts a rule below, flag it — don't imitate it.

## Repo mechanics

New `.swift` files must be registered in
`HeartlabsEcho.xcodeproj/project.pbxproj`:

1. `PBXFileReference` entry with a unique 8-char hex UUID
2. `PBXBuildFile` entry referencing that UUID
3. The UUID in the `HeartlabsEcho` `PBXGroup` children array
4. The UUID in the `PBXSourcesBuildPhase` files array

Search for any existing file's UUID to see the exact pattern. Deleting a
file means removing all four entries.

## Engineering principles

### State & structure

1. **One fact, one home.** Every piece of state has exactly one owning type;
   everything else reads it or receives it as an immutable value. Never keep
   a second copy synced by callbacks or subscriptions — if two properties
   must be kept in agreement, the design is already wrong.
2. **Lifecycles are state machines.** Anything with a lifecycle (a flow, a
   recording, a request) gets ONE stored `phase`/`state` enum — never a
   constellation of booleans, and never an enum so coarse that one case
   means several different situations. Every event handler is an exhaustive
   `switch` over that enum with deliberate, commented no-op cases. Litmus:
   adding a new state must refuse to compile until every handler decides
   what it means.
3. **Guard flags are a smell.** `isFinishing`, `isBusy`, `didAlreadyX`, or
   "remember to nil the callback before stopping" all mean a state or an
   owner is missing. If correctness depends on remembering to do something,
   restructure until forgetting is impossible (one-shot objects, exhaustive
   switches, restricted init visibility).
4. **Make wrong code unrepresentable.** Prefer one-shot objects over
   restartable ones. Values that prove something ("recording is finished")
   get restricted inits so only the legitimate producer can create them.
   `private(set)` every published property; expose intents (methods), not
   setters.
5. **Views render and forward.** Views own zero lifecycle state: they draw
   the model's state and translate gestures into intent method calls. A view
   that decides, cleans up, retries, or dismisses is a bug. There should be
   no code path a view can take that the owning model cannot account for.

### Concurrency

6. **The world changes at every `await`.** After every suspension, re-check
   the state you're about to mutate. Late or duplicate callbacks are
   rejected by identity or by phase — never by hoping they won't happen.
7. **Every wait is bounded.** Never store a continuation without a
   guaranteed resumer; race long waits against a timeout. No user action may
   ever hang the UI on an await.
8. **Cancellation is part of setup, not an afterthought.** Cancellable async
   operations check for cancellation after every await and tear down fully
   on the way out. Ask at each line: "what happens if the user aborts right
   here?" — the answer must never be "the resource stays acquired".
9. **Events flow through streams and return values** — never through
   settable closure properties, never through published-optional fields that
   the listener sets back to nil. If a component needs to report things,
   give it an `AsyncStream`, a returned value, or a constructor-injected
   callback that is set exactly once.

### Resources

10. **One owner per resource.** Files, hardware sessions, audio engines,
    tasks: exactly one type acquires them, and exactly one place releases or
    transfers them — on every exit path, including errors, cancellation, and
    backgrounding. If you can't name the owner, you've found a bug.

### Change discipline

11. **Weird code is load-bearing until proven otherwise.** Delays, grace
    periods, redundant-looking calls, missing "obvious" cleanups, odd
    orderings: check the comment and git history before "fixing" them. Some
    absences are deliberate (they carry warning comments at the site). If
    you keep a weirdness, make sure it's commented WHY; if you remove one,
    say so explicitly in the commit message so it can be traced. But once
    you PROVE something dead (a state never entered, a branch never taken),
    do not preserve it as a quirk — unreachable states contradict rule 2.
    Flag it and propose either wiring it up or deleting it; the user decides.
12. **Refactors start from behavior, not code.** Before rewriting, enumerate
    the observable behaviors and edge cases — interruptions, backgrounding,
    double-taps, gesture races, system timeouts, process restarts — and
    decide each one explicitly. UX stays identical unless a change was
    agreed. If you can't enumerate the edge cases, you don't understand the
    code well enough to rewrite it yet. The inventory MUST include an await
    sweep: list every `await` in the touched code and state, for each one,
    what can change during the suspension and how the code re-validates
    afterwards. Untreated awaits are where the races live — an inventory
    without this sweep only catalogs the happy paths.
13. **YAGNI, precisely.** Every abstraction must be paid for by variation
    that exists today (two implementations → protocol; one → no protocol).
    No speculative config, no "for the future" parameters, no third
    implementation. Simple and rigid beats flexible and vague.
14. **Comments state contracts and why — never what.** File headers say what
    the component owns, does, and deliberately never does. Warnings live at
    the exact site where a future edit would go wrong, not in a distant
    document.
15. **Every error site has a decided policy.** Use `os.Logger` (never `print`)
    for all diagnostics — `print` ships in release builds; `os.Logger` is
    stripped. The shared loggers live in `UserSettings.swift` (subsystem
    `com.heartlabsecho`). Per-call-site decisions:
    - **Journal-save failures** (`ConversationService.saveChanges`): log an
      error AND fire `assertionFailure` in DEBUG builds — a failed save
      silently loses the app's core data, so crashing in dev is the correct
      tradeoff. In release, the error is logged and the app continues (the
      user's entry may be lost, but the app stays usable).
    - **Goal fetch errors**: log and return `[]`/`nil` — goals are secondary;
      a failed fetch should not block the conversation.
    - **Image I/O errors**: log and return `nil` — missing images degrade to
      the fallback emoji, which is an acceptable UX fallback.
    - **LLM errors**: log and surface a user-visible error message in the
      chat (see `ConversationEngine.sendToLLM`).
    - **Speech recognition diag**: `Logger.speech.debug` — these are
      development traces, not errors.
    - **ModelRouter fallback**: `Logger.llm.warning` — a planned degradation.
    - **ChatMessage role fallback**: `Logger.chat.warning` — a corrupted
      store, not a normal path.
16. **Edit sheets are drafts with explicit commit/discard.** No global state
    changes before Save; every picked/created resource has an owner on both
    the save path and the cancel path (e.g. saved photos are deleted only on
    commit, picked-then-discarded photos are cleaned up on cancel).

## Definition of done

- Builds without new warnings.
- Every claim about existing code (line counts, dead code, callers, "never
  set") is verified by command output (`wc -l`, `grep -n`, …) — never
  estimated.
- For every new or touched async path you can answer: what happens if it's
  cancelled mid-way? backgrounded? triggered twice? Does every wait end?
- No new mirrored state, guard flags, or settable event closures.
- Resource ownership is explicit on every exit path you added or changed.
- Header/doc comments of every touched file updated in the same commit.
- New files registered in `project.pbxproj` (all four entries).
- Hardware-adjacent code (microphone, audio session, speech) verified on a
  real device — the simulator lies about audio, and some system behaviors
  (recognition timeouts, on-device vs. network models) differ per device.
