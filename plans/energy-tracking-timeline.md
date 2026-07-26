# Energy Level Tracking — Timeline Extension Plan

## 1. Rust Data Model Changes

### 1.1 New Types

```rust
// core/src/domain/entities/game.rs

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum EnergyLevel {
    Green,   // thriving
    Yellow,  // danger to go red
    Red,     // bad
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub enum TimelineEntryData {
    CheckIn {
        energy_level: EnergyLevel,
        description: String,
    },
    QuestCompletion {
        quest_id: Uuid,
    },
}
```

### 1.2 Modified `TimelineEntry`

```rust
pub struct TimelineEntry {
    pub id: Uuid,
    pub occurred_on: DateTime<Utc>,
    pub data: TimelineEntryData,
}
```

**Rationale:** Removing the flat `quest_id: Uuid` (was mandatory) and replacing it with a variant enum. This eliminates invalid states — a `CheckIn` can never have a dangling quest reference, and a `QuestCompletion` always has a `quest_id`.

**Design decisions:**
- `QuestCompletion` does **not** carry its own `energy_level` or `description`.
- `CheckIn.description` is mandatory — the user must always write something about their state.
- The description for quest completions is auto-generated at normalization time (e.g. `"Completed quest: <title>"`).
- Quest completions **never** show an energy level — the UI renders nothing for them (see §5).

### 1.3 Modified `TimelineRepository` Trait

```rust
// core/src/domain/ports/timeline_repository.rs

#[async_trait]
pub trait TimelineRepository: Send {
    async fn record(&mut self, entry: TimelineEntry) -> Result<(), GameError>;
    async fn find_by_date(&self, day: NaiveDate) -> Vec<TimelineEntry>;
    async fn remove(&mut self, id: Uuid) -> Result<(), GameError>;
    
    /// Reassign a QuestCompletion entry to a different quest.
    /// Returns GameError if the entry is not a QuestCompletion variant.
    async fn reassign(&mut self, entry_id: Uuid, quest_id: Uuid) -> Result<(), GameError>;
    
    /// Update the energy level of a CheckIn entry.
    /// Returns GameError if the entry is not a CheckIn variant.
    async fn update_energy_level(&mut self, entry_id: Uuid, level: EnergyLevel) -> Result<(), GameError>;
}
```

### 1.4 Points Resolution Logic

Points are resolved in Rust during the normalized view construction (not stored on the entry):

- `CheckIn` → **5 points** (hardcoded)
- `QuestCompletion` → look up quest's `points` field

`GameService::total_points` branches on variant.

### 1.5 New Tool: `record_check_in`

```rust
ToolDefinition {
    name: "record_check_in",
    description: "Record a check-in with the user's current energy level. "
                 "The first timeline entry of every day MUST be a check-in. "
                 "If you're about to complete a quest but no check-in exists "
                 "for today, call record_check_in first.",
    parameters: {
        "type": "object",
        "properties": {
            "level": { "type": "string", "enum": ["green", "yellow", "red"], "description": "Current energy level" },
            "description": { "type": "string", "description": "Note about the user's current state" }
        },
        "required": ["level", "description"],
        "additionalProperties": false
    }
}
```

Creates a `TimelineEntry` with `CheckIn { energy_level, description }`. Awards 5 points.

### 1.6 Modified `complete_quest` Tool

No longer takes `energy_level` as a parameter (QuestCompletion doesn't carry it). The AI is responsible for ensuring a CheckIn exists for the day before calling `complete_quest`. If the AI wants to record a change in energy level before completing a quest, it makes **two calls**: `record_check_in` then `complete_quest`.

**`GameService::complete_quest` internally** changes from:
```rust
TimelineEntry { id: Uuid::new_v4(), quest_id, occurred_on: Utc::now() }
```
to:
```rust
TimelineEntry { id: Uuid::new_v4(), occurred_on: Utc::now(), data: TimelineEntryData::QuestCompletion { quest_id } }
```

---

## 2. Rust → WASM Bindings

### 2.1 New/Modified WASM Exports

| Export | Change |
|---|---|
| `getTimelineForDate(year, month, day)` | Now serializes the normalized view (see §4). Returns JSON with `type` field distinguishing check-in vs quest entry. |
| `(new) updateTimelineEntryEnergy(entryId, level)` | New export. Loads cache, updates `CheckIn.energy_level`, persists. Errors if entry is a `QuestCompletion`. |
| `setTimelineRepositoryCallbacks` | Unchanged — same two callbacks (`loadTimeline`, `saveTimeline`) still used. |

### 2.2 `WasmTimelineRepository` Changes

The in-memory cache still stores `Vec<TimelineEntry>` with the new enum. The JS persistence layer serializes/deserializes the full enum (serde handles this transparently).

---

## 3. New/Modified GameService Methods

```rust
// GameService additions
pub async fn record_check_in(
    &mut self, 
    energy_level: EnergyLevel, 
    description: String
) -> Result<TimelineEntry, GameError> {
    // Creates a CheckIn entry, stores it, returns it
}

pub async fn update_entry_energy(
    &mut self,
    entry_id: Uuid,
    level: EnergyLevel,
) -> Result<(), GameError> {
    // Delegates to timeline_repo.update_energy_level
}
```

---

## 4. Normalized JS View (Rust side)

The `getTimelineForDate` function constructs a normalized JSON view for the JS consumers. This is the **key mapping layer** — Rust handles the enum complexity so JS sees a flat, predictable shape.

### Rust: Normalized Entry Shape

The Rust side produces a flat, unified JSON shape. JS never needs to resolve quests or
reason about enum variants — it just renders what it gets.

```rust
// Constructed in getTimelineForDate

fn build_normalized_view(entry, quests) -> serde_json::Value {
    match entry.data {
        TimelineEntryData::CheckIn { energy_level, description } => json!({
            "id": entry.id,
            "occurredOn": entry.occurred_on,
            "type": "check_in",
            "energyLevel": energy_level,       // "green" | "yellow" | "red"
            "description": description,
            "points": 5,
        }),
        TimelineEntryData::QuestCompletion { quest_id } => {
            let quest = find_quest(quest_id);
            json!({
                "id": entry.id,
                "occurredOn": entry.occurred_on,
                "type": "quest_completion",
                "energyLevel": null,            // never inherited — always null
                "description": format!("Completed quest: {}", quest.title),
                "points": quest.points,
            })
        }
    }
}
```

**Cross-day rule:** `energyLevel` inheritance is scoped to **same calendar day only**.
A quest completion on Monday without a preceding Monday CheckIn shows `null`,
even if a CheckIn exists on Tuesday. Not inherited across days.

### JS: Consumed Shape

```typescript
// What JS actually sees — flat, no quest knowledge needed

interface TimelineEntryView {
    id: string;
    occurredOn: string;        // RFC3339
    type: 'check_in' | 'quest_completion';
    energyLevel: string | null; // "green" | "yellow" | "red" | only non-null for check_in
    description: string;
    points: number;
}
```

**Key differences from today's flat model:**
- `energyLevel` is new — present for `check_in`, always `null` for `quest_completion`
- `description` is always a string (CheckIn has its own; QuestCompletion gets auto-generated `"Completed quest: <title>"`)
- No `questId` or `questTitle` — JS doesn't need to know about quests at all
- `type` field lets JS decide whether to render an energy dot at all (only `check_in`)

**`totalPoints`** remains in the response: sum of all entry points for the day.

### Tool Output Formatting (LLM-facing)

The `execute_list_timeline` and `execute_list_open_quests` handlers currently format
timeline entries as flat strings for the LLM. With the new enum, they must match on the variant.

**Before (current):**
```
  - id: d3a..., quest: "Boost confidence" (id: b7f...), time: 14:32:15, points: 25, description: "Practice one assertive statement daily"
```

**After (with enum):**
```
  - id: a1b..., type: check_in, time: 09:15:00, energy: green, description: "Woke up feeling motivated", points: 5
  - id: d3a..., type: quest_completion, time: 14:32:15, quest: "Boost confidence", quest_id: b7f..., points: 25, description: "Practice one assertive statement daily"
```

Key changes for quest entries:
- Added `type: quest_completion` field
- `quest` shows only the title; `quest_id` is a separate explicit field (no ambiguous `(id: uuid)`)
- `description` still shows the **quest's description**, not the auto-generated UI string
- No `energy` field for quest entries

The auto-generated description `"Completed quest: <title>"` is only for the JS normalized view — the LLM gets more detail.

```rust
for entry in &entries {
    match &entry.data {
        TimelineEntryData::CheckIn { energy_level, description } => {
            lines.push(format!(
                "  - id: {}, type: check_in, time: {}, energy: {:?}, description: \"{}\", points: 5",
                entry.id, entry.occurred_on.format("%H:%M:%S"), energy_level, description,
            ));
        }
        TimelineEntryData::QuestCompletion { quest_id } => {
            if let Ok(Some(quest)) = game.find_quest_by_id(*quest_id).await {
                lines.push(format!(
                    "  - id: {}, type: quest_completion, time: {}, quest: \"{}\", quest_id: {}, points: {}, description: \"{}\"",
                    entry.id, entry.occurred_on.format("%H:%M:%S"), quest.title, quest.id, quest.points, quest.description,
                ));
            } else {
                lines.push(format!(
                    "  - id: {}, type: quest_completion, time: {}, quest: (deleted)",
                    entry.id, entry.occurred_on.format("%H:%M:%S"),
                ));
            }
        }
    }
}
```

This keeps the LLM-facing output clean and flat — no raw enum serialization leaks through.

---

## 5. JS Side — UI Changes

### 5.1 `timeline-block.js` and `quest-view.js`

Both renderers currently show a 3-column row:

```
[timestamp]  [quest title]  [+points]
```

New layout:

```
[●]  [timestamp]  [description]  [+points]     ← check_in (energy dot visible)
     [timestamp]  [description]  [+points]     ← quest_completion (no energy dot)
```

- The **energy dot** is a colored circle (green/yellow/red) to the left of the timestamp,
  rendered **only for `check_in` entries**. Quest completions get no dot at all —
  the row starts with the timestamp.
- The description column shows either the check-in note or `"Completed quest: <title>"`.
- **Energy editing:** Clicking the dot opens a **dropdown** (green/yellow/red)
  to change the level. The dropdown's `change` handler calls `updateTimelineEntryEnergy(entryId, newLevel)`.
  The click handler **must call `e.stopPropagation()`** to prevent the row's
  expand/collapse toggle from also firing.
- **Quest completions:** No dot, no dropdown, not editable. The `type` field determines this.

### 5.2 CSS additions

```css
.quests-timeline-energy {
    width: 12px; height: 12px;
    border-radius: 50%;
    flex-shrink: 0;
    cursor: pointer;
    position: relative;
}
.quests-timeline-energy.energy-green  { background: #22c55e; }
.quests-timeline-energy.energy-yellow { background: #eab308; }
.quests-timeline-energy.energy-red    { background: #ef4444; }
.quests-timeline-energy.energy-none   { background: var(--text-faint); opacity: 0.3; }
```

### 5.3 Energy Dropdown

A small dropdown that appears on click (or as a `<select>` inline). For intentionality — user must explicitly pick, no accidental clicks.

---

## 6. Implementation Order

| Step | Files | Description |
|---|---|---|
| 1 | `core/src/domain/entities/game.rs` | Add `EnergyLevel` enum, `TimelineEntryData` enum. Modify `TimelineEntry`. Update `points` resolution. |
| 2 | `core/src/domain/ports/timeline_repository.rs` | Add `update_energy_level` to trait. Keep `reassign`. |
| 3 | `core/src/domain/entities/game.rs` | Add `record_check_in` and `update_entry_energy` to `GameService`. Update `complete_quest` to handle new model. |
| 4 | `core/src/domain/tools/mod.rs` | Add `record_check_in` tool definition and executor. Update `complete_quest` tool. |
| 5 | `core/src/infrastructure/in_memory_timeline_repo.rs` | Implement `update_energy_level`. Update `reassign` to error on non-QuestCompletion. |
| 6 | `core-wasm/src/{lib,timeline_repository}.rs` | Implement `update_energy_level` in `WasmTimelineRepository`. Add `updateTimelineEntryEnergy` WASM export. Update `getTimelineForDate` to produce normalized view. **Extend `clearGameData`** to also clear the timeline cache: move the function to `lib.rs` and call `quest_repository::clear_cache()` + `timeline_repository::clear_cache()`. |
| 7 | `obsidian-plugin/src/lib/timeline-block.js` | Render energy dot + dropdown. Wire up `updateTimelineEntryEnergy` call. |
| 8 | `obsidian-plugin/src/lib/quest-view.js` | Same render changes for the quest panel timeline. |
| 9 | `obsidian-plugin/src/styles.css` | Add styles for energy dot and dropdown. |

---

## 7. Migration & Error Handling

Existing `data.timeline` entries in user vaults have the old shape `{ id, questId, occurredOn }`.
The WASM `ensure_cache_loaded` will attempt to deserialize them into the new enum —
they **will fail** because the variant discriminator `data` is missing.

**Approach: Hard fail with user-facing error.**
- `ensure_cache_loaded` propagates the serde error (it already does).
- `getTimelineForDate` catches it and returns a `JsError` with a clear message:
  `"Timeline data format is outdated. Go to Plugin Settings → Data → Reset Game Data."`
- `chatCompletion` (which calls `GameService` methods internally) will bubble up the error
  to the JS side as a caught exception shown in the chat UI.

**Plugin must load enough for the reset button to work.**
- The settings tab (`settings.js`) calls `plugin.loadData()` (Obsidian API) directly —
  this works independently of WASM. The user can navigate to Settings → Data → Reset
  Game Data even if timeline deserialization fails.
- `clearGameData()` WASM export **must also clear the timeline cache** for the reset
  to take full effect. Currently it only clears the quest cache.

No migration code. Users who have old data must reset. This is acceptable since the
plugin is still in early development.

---

## 8. Open Questions / Future

None — no further abstractions planned for now. The enum-based design is flexible
enough for future feature entries if needed.
