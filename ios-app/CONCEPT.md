# iOS App Concept

## What is this?

The iOS app is a **proof-of-concept** for a different take on the journaling
assistant idea. It's an unfiltered experiment — we're trying things out,
seeing what sticks, and iterating fast.

---

## Why not reuse the prompt-yourself core?

The existing `prompt-yourself-core` crate has a specific philosophy:

| Aspect | prompt-yourself core | iOS app (idea) |
|---|---|---|
| Journal format | Structured: motivation section + daily log focused on a growth goal | Free-form conversation, entirely speech-to-text |
| Philosophy | Coach + mirror, "look at the blank page", step-by-step reflection | Listens without judgement, no advice, no structure |
| Growth goal | Required — the whole system revolves around it | Not required — the user can talk about anything |
| Onboarding | Strict: refuses to proceed without proper journal | Minimal — just start talking |
| Quests / timeline | Built-in gamification system | Not planned |
| Methodology | "Tune into yourself", empty page stimulates reflection | Straight conversation, remembering past insights |
| Output | Structured coaching responses | Natural conversation with references to past topics |

Trying to retrofit the core for this would mean disabling most of its
features or fighting against its fundamental assumptions. The overlap is
essentially just "calls an LLM API with a conversation history" — about
50 lines of code. A native Swift service is cleaner.

---

## Current ideas for the app (still evolving)

### Core concept
- A voice-based companion that **listens without judgement**
- Does **not give advice** — mirrors, reflects, helps the user hear
  themselves think
- **Remembers past conversations** — references past learnings, spots patterns
  emerging over time ("you've mentioned this three times this week")

### Key features we want to explore
- **Pure speech-to-text interface** — no typing, just tap and speak
- **Long-running conversations** — the app builds a persistent understanding
  of the user over days, weeks, months
- **Pattern recognition** — surfaces recurring themes the user might not
  notice themselves
- **No goals, no pressure** — you don't need a "growth goal" to use it.
  Just talk about whatever is on your mind

### Explicit non-goals (things we are NOT building)
- Structured journal templates
- Goal tracking or quest systems
- Step-by-step coaching methodology
- "Blank page" reflection prompts

### Open questions we're playing with
- What does the UI look like when there's no typing? Just voice in, voice out?
  Text transcript of both sides?
- How does "remembering past conversations" work in practice? Per-session
  summaries? Embedding-based retrieval?
- What system prompt produces a listener that mirrors without being
  repetitive or robotic?
- How long should a "session" be? One topic? A timebox? Natural end detection?

---

## This is a POC

None of this is final. We're building a prototype to see what feels right.
Expect:
- Abandoned experiments
- Half-baked features
- Architectural U-turns

That's the point. If something doesn't work, we'll scrap it and try
something else.