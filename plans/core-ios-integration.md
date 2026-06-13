# core-ios: Bridging the Rust Core to iOS/Swift

## Goal

Create a new `core-ios` crate that wraps `prompt-yourself-core` into a static
library (`.a`) that the iOS app can link directly from Swift.

Uses **UniFFI** (Mozilla) to generate type-safe Swift bindings from the Rust
interface — no raw C pointers, no manual memory management, no `strdup`/`free`.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                 iOS App (Swift)                  │
│  ┌───────────────────────────────────────────┐   │
│  │           View / UI layer                 │   │
│  └──────────────────┬────────────────────────┘   │
│                     │ calls generated Swift API   │
│  ┌──────────────────▼────────────────────────┐   │
│  │          UniFFI-generated bindings         │   │
│  │  (clean Swift types, async throws)         │   │
│  └──────────────────┬────────────────────────┘   │
│                     │ FFI boundary               │
│  ┌──────────────────▼────────────────────────┐   │
│  │         core-ios (static lib .a)           │   │
│  │  ┌────────────────────────────────────┐    │   │
│  │  │  UniFFI scaffolding + exports      │    │   │
│  │  │  (#[uniffi::export] functions)     │    │   │
│  │  └────────────┬───────────────────────┘    │   │
│  │               │                    ▲        │   │
│  │  ┌────────────▼────────────────────┼────┐   │   │
│  │  │  Adapters (Journal, Quest, …)   │    │   │   │
│  │  │  delegate to registered Swift   │    │   │   │
│  │  │  callbacks via function pointers │    │   │   │
│  │  └─────────────────────────────────┘    │   │   │
│  └──────────────────────────────────────────┘   │
│                                                 │
│  ┌──────────────────────────────────────────┐   │
│  │  core (Rust domain logic)                 │   │
│  │  - Chat engine                            │   │
│  │  - Quest/timeline game service            │   │
│  │  - YAML document producer                 │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

The **adapter layer still uses function pointers internally** (that's how
ports-and-adapters works on any non-native target — same as WASM's JS
callbacks). The difference is that **Swift never sees them**.

---

## Communication Pattern

Following the ports-and-adapters pattern, the core owns all state (chat
history, quests, timeline, last-check timestamp). It calls **out** to Swift
via registered callbacks when it needs data:

| Port | WASM approach | iOS approach |
|---|---|---|
| **JournalPort** | JS callback via `setLoadEntriesCallback` | UnsafeCallback trait, Swift registers handler |
| **QuestRepository** | JS callbacks for load/save | Swift passes closures via UniFFI callback interface |
| **TimelineRepository** | JS callbacks for load/save | Swift passes closures via UniFFI callback interface |
| **OpenAiPort** | `async-openai-wasm` (Rust) | Same crate — works on iOS natively |

Callbacks are registered at startup. All data crosses the boundary as JSON
strings (serialized by UniFFI automatically).

---

## UniFFI Interface

A `.udl` file (or inline proc macros) defines the interface contract:

```rust
// core-ios/src/lib.rs

uniffi::setup_scaffolding!();

/// Registered once at startup. Swift provides the implementation.
#[uniffi::export(callback_interface)]
pub trait JournalProvider: Send {
    fn load_entries(since_ms: i64) -> Result<String, String>;
}

#[uniffi::export(callback_interface)]
pub trait QuestStore: Send {
    fn load_quests() -> Result<String, String>;
    fn save_quests(json: String) -> Result<(), String>;
}

#[uniffi::export(callback_interface)]
pub trait TimelineStore: Send {
    fn load_timeline() -> Result<String, String>;
    fn save_timeline(json: String) -> Result<(), String>;
}

#[uniffi::export]
pub fn core_init(
    api_key: String,
    api_base: String,
    model: String,
    journal: Box<dyn JournalProvider>,
    quests: Box<dyn QuestStore>,
    timeline: Box<dyn TimelineStore>,
) -> Result<(), String>;

#[uniffi::export]
pub fn core_load_initial_context() -> Result<u32, String>;

#[uniffi::export]
pub async fn core_user_message(text: String, day_ms: i64) -> Result<String, String>;

#[uniffi::export]
pub fn core_get_game_state() -> Result<String, String>;

#[uniffi::export]
pub fn core_get_token_usage() -> Result<String, String>;

#[uniffi::export]
pub fn core_set_test_mode(enabled: bool) -> Result<(), String>;
```

---

## Crate Structure

```
core-ios/
├── Cargo.toml
├── src/
│   ├── lib.rs              ← UniFFI exports + scaffolding
│   ├── journal_adapter.rs  ← JournalPort impl via UniFFI callback interface
│   ├── quest_adapter.rs    ← QuestRepository impl via UniFFI callback interface
│   ├── timeline_adapter.rs ← TimelineRepository impl via UniFFI callback interface
│   └── reentry_guard.rs    ← Same pattern as core-wasm (copy)
├── uniffi-bindgen.rs       ← Binary entry for generating bindings
├── build-ios.sh            ← Cross-compile + binding generation script
└── README.md
```

## Cargo.toml

```toml
[package]
name = "prompt-yourself-core-ios"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib"]
name = "prompt_yourself_core_ios"

[dependencies]
prompt-yourself-core = { path = "../core" }
uniffi = { version = "0.28", features = ["cli"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
chrono = "0.4"
async-trait = "0.1"
uuid = { version = "1", features = ["v4", "serde"] }
tokio = { version = "1", features = ["rt", "macros", "sync"] }

[[bin]]
name = "uniffi-bindgen"
path = "uniffi-bindgen.rs"
```

## uniffi-bindgen.rs

```rust
fn main() {
    uniffi::uniffi_bindgen_main()
}
```

## Build Script (build-ios.sh)

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DEVICE="aarch64-apple-ios"
TARGET_SIM="aarch64-apple-ios-sim"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure cross-compilation targets are installed
rustup target add $TARGET_DEVICE $TARGET_SIM

# Build for physical device
cargo build --release --target $TARGET_DEVICE

# Build for simulator (for local testing)
cargo build --release --target $TARGET_SIM

# Generate Swift bindings from the device binary
cargo run --bin uniffi-bindgen -- generate \
  --library target/$TARGET_DEVICE/release/libprompt_yourself_core_ios.a \
  --language swift \
  --out-dir ./bindings/

echo ""
echo "Done! Bindings generated in bindings/"
echo "  → bindings/prompt_yourself_core_ios.swift"
echo "  → bindings/prompt_yourself_core_ios.h"
echo "  → bindings/prompt_yourself_core_ios.modulemap"
echo ""
echo "The .a archive:"
echo "  target/$TARGET_DEVICE/release/libprompt_yourself_core_ios.a (device)"
echo "  target/$TARGET_SIM/release/libprompt_yourself_core_ios.a (simulator)"
```

---

## Xcode Integration Steps

1. **Add the static library** to the project:
   - Drag `libprompt_yourself_core_ios.a` into Xcode (or reference it)
   - Under Build Settings → `Library Search Paths`: add the path to the `.a`

2. **Add the generated Swift source**:
   - Drag `bindings/prompt_yourself_core_ios.swift` into Xcode

3. **Configure the module map**:
   - Under Build Settings → `Swift Compiler - Search Paths / Import Paths`:
     add path to `bindings/` (where `.modulemap` lives)

4. **Add `libresolv.tbd`** (UniFFI requirement):
   - Build Phases → Link Binary With Libraries → add `libresolv.tbd`

5. **Run the build script** as a pre-build phase (optional):
   - Add a "Run Script" build phase that calls `build-ios.sh`
   - This auto-rebuilds the `.a` whenever you change Rust code

---

## Swift Usage (after setup)

```swift
import prompt_yourself_core_ios

// 1. Create adapter implementations
class MyJournalProvider: JournalProvider {
    func loadEntries(sinceMs: Int64) -> Result<String, String> {
        // Read journal from app's files/repository
        // Return JSON string of entries
    }
}

class MyQuestStore: QuestStore {
    let coreData: NSManagedObjectContext
    func loadQuests() -> Result<String, String> { ... }
    func saveQuests(json: String) -> Result<(), String> { ... }
}

class MyTimelineStore: TimelineStore {
    func loadTimeline() -> Result<String, String> { ... }
    func saveTimeline(json: String) -> Result<(), String> { ... }
}

// 2. Initialize
try coreInit(
    apiKey: "sk-...",
    apiBase: "https://api.deepseek.com",
    model: "deepseek-chat",
    journal: MyJournalProvider(),
    quests: MyQuestStore(),
    timeline: MyTimelineStore()
)

// 3. Load initial context
try coreLoadInitialContext()

// 4. Chat
let reply = try await coreUserMessage(
    text: "What did I write about my goal yesterday?",
    dayMs: todayMS
)
// reply is a String — JSON array of ChatMessage objects
```

---

## Implementation Order

| Step | Description | Depends on |
|---|---|---|
| 1 | Create `core-ios/` crate scaffold (Cargo.toml, lib.rs, uniffi-bindgen.rs) | — |
| 2 | Implement `reentry_guard.rs` | core-wasm copy |
| 3 | Implement `journal_adapter.rs` (JournalPort via UniFFI callback) | core's JournalPort trait |
| 4 | Implement `quest_adapter.rs` + `timeline_adapter.rs` | core's repository traits |
| 5 | Implement full UniFFI exports (init, chat, game state, cleanup) | adapters above |
| 6 | Write `build-ios.sh` cross-compile + binding generation script | — |
| 7 | Update `AGENTS.md` with core-ios notes | — |

---

## What We Can and Can't Verify from the Container

| Task | In container | On Mac host |
|---|---|---|
| Write crate code | ✅ | — |
| `cargo check` (x86_64, stub target) | ✅ | — |
| Cross-compile for `aarch64-apple-ios` | ❌ (needs iOS SDK) | ✅ |
| Run `uniffi-bindgen` to generate Swift bindings | ❌ (needs compiled .a) | ✅ |
| Add files to Xcode project | ❌ | ✅ |
| Build & run the full app | ❌ | ✅ |

The build script must be executed on the host Mac (or we revisit the xtool
cross-compilation approach from `CROSS_COMPILE.md`).

---

## Open Questions

1. **Callback thread safety**: UniFFI callback interfaces use `Send + Sync`
   internally. Does the Swift implementation need to handle dispatch to
   `@MainActor` itself?
2. **Async runtime**: The core uses `async-trait`. We need a Tokio runtime
   — single-threaded (`current_thread`) or multi-threaded?
3. **Re-entrancy**: Same concern as WASM — callbacks must not re-enter the
   chat lock. Re-use the `ReentryGuard` from core-wasm.
