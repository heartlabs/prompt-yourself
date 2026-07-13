---
name: fork-you
description: Spawn a twin subagent from the current pi session via --fork. The twin inherits full conversation context (AGENTS.md, prior work, decisions). Use when delegating chunks of work to a context-rich subagent that acts like you.
---

# Fork You

Spawns a twin pi agent with full conversation context via `--fork`.

## Why

Writing task descriptions manually loses context, takes time, and drifts. A forked twin **is you** — it sees the entire conversation, knows AGENTS.md rules, completed work, and pending decisions. You just tell it to continue.

## Workflow

### 1. Get the current session ID

Run `/session` in your pi session. Note the `ID:` line.

```
Session Info
 ID: 019f576c-ba93-7e5f-a7ed-29fbe2c61878
```

**Every new pi session gets a new ID.** Always re-check.

### 2. Spawn the twin

```bash
pi --fork <session-id> -p "Continue with chunk X: brief description."
```

The `-p` prompt should be minimal — the twin has full context. Just give it direction:

```
"Continue with chunk B (P1.3): typed persistence boundary. Implement, verify with grep, report."
```

### 3. The twin works and reports

It reads files, makes edits, runs grep verifications, and returns a summary. Forward the result or act on it.

## Gotchas

- **Wrong session ID** → twin sees a different branch entirely. If the twin talks about unrelated work, check `/session` again.
- **`--fork` + `--no-session` don't combine.** The fork creates a session file; accept it.
- **Don't write a book as the prompt.** The twin already has the gap analysis, AGENTS.md, project rules, and all prior conversation. One sentence of direction is enough.
- **Build/test on macOS only.** The Linux container can't compile the iOS app. The twin can edit and verify with grep, but only a human on macOS can build and run.
- **After the twin finishes**, the fork creates a new session file in `~/.pi/agent/sessions/`. These accumulate — clean up periodically.
