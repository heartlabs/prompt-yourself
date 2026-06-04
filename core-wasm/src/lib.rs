//! # WASM bindings for prompt-yourself-core
//!
//! This crate provides `#[wasm_bindgen]` exports that wrap the domain logic
//! in `prompt-yourself-core` for consumption from JavaScript (e.g., the Obsidian plugin).
//!
//! ## Architecture
//!
//! The WASM adapter for [`JournalPort`] delegates to a JS callback registered
//! via [`setLoadEntriesCallback`]. This means from the **core**'s perspective
//! there is zero difference between the CLI and Obsidian — both just implement
//! `load_entries(since)` and the core calls it at the right times.
//!
//! ## Re-entrancy guard
//!
//! The JS callback **must not** call back into any WASM function that locks
//! [`CHAT`] (e.g. [`chatCompletion`], [`loadInitialContext`]), or a deadlock
//! will occur. A [`ReentryGuard`] is checked before `load_entries` calls into
//! JS, and will return an error if re-entrancy is detected.

use std::cell::RefCell;
use std::sync::{Mutex, OnceLock};

mod reentry_guard;
mod quest_repository;
mod timeline_repository;

pub use quest_repository::wasm_set_quest_repository_callbacks as setQuestRepositoryCallbacks;
pub use quest_repository::wasm_clear_game_data as clearGameData;
pub use timeline_repository::wasm_set_timeline_repository_callbacks as setTimelineRepositoryCallbacks;
pub use timeline_repository::wasm_get_timeline_for_date as getTimelineForDate;

// Set a panic hook that logs to console.error so we can see Rust panic
// messages instead of just "RuntimeError: unreachable".
#[wasm_bindgen(start)]
pub fn start() {
    console_error_panic_hook::set_once();
}

use chrono::{DateTime, Utc};
use prompt_yourself_core::{
    api::chat::Chat,
    domain::ports::journal::{JournalError, JournalPort},
    yaml_producer::FileEntry,
    OpenAiAdapter,
};
use wasm_bindgen::prelude::*;

// ─── Global state ───────────────────────────────────────────────────────────

static API_KEY: OnceLock<String> = OnceLock::new();
static API_BASE: OnceLock<String> = OnceLock::new();
static CHAT: OnceLock<Mutex<Chat>> = OnceLock::new();

// JS callback registered by the Obsidian plugin.
// Signature: `(sinceMs: number) => Promise<string>`
thread_local! {
    static LOAD_ENTRIES_CALLBACK: RefCell<Option<js_sys::Function>> = const { RefCell::new(None) };
}

// Re-entrancy guard (WASM only — native stub never instantiates WasmJournalAdapter).
// WASM is single-threaded, so we use a simple thread-local boolean.
#[cfg(target_arch = "wasm32")]
thread_local! {
    static REENTRY_GUARD: RefCell<bool> = const { RefCell::new(false) };
}

#[cfg(target_arch = "wasm32")]
struct ReentryGuard;
#[cfg(target_arch = "wasm32")]
impl ReentryGuard {
    fn try_enter() -> Result<Self, String> {
        REENTRY_GUARD.with(|g| {
            let mut guard = g.borrow_mut();
            if *guard {
                return Err("Re-entry detected: the loadEntries callback must not call back into WASM functions (e.g. chatCompletion)".to_string());
            }
            *guard = true;
            Ok(ReentryGuard)
        })
    }
}
#[cfg(target_arch = "wasm32")]
impl Drop for ReentryGuard {
    fn drop(&mut self) {
        REENTRY_GUARD.with(|g| *g.borrow_mut() = false);
    }
}

// ─── WASM journal adapter ───────────────────────────────────────────────────

/// Adapter that calls a JS callback to load file entries.
///
/// The callback is registered via [`setLoadEntriesCallback`] and must return
/// a JSON-serialized `Vec<FileEntry>`.
struct WasmJournalAdapter;

// The adapter is only ever instantiated on WASM. On native (host-target builds
// like `cargo check --workspace`) we provide a stub that panics — this keeps
// the compiler happy while we still use ?Send on WASM.
#[cfg(not(target_arch = "wasm32"))]
#[async_trait::async_trait]
impl JournalPort for WasmJournalAdapter {
    async fn load_entries(&self, _since: &DateTime<Utc>) -> Result<Vec<FileEntry>, JournalError> {
        unreachable!("WasmJournalAdapter should never be used on native targets")
    }
}

#[cfg(target_arch = "wasm32")]
#[async_trait::async_trait(?Send)]
impl JournalPort for WasmJournalAdapter {
    async fn load_entries(&self, since: &DateTime<Utc>) -> Result<Vec<FileEntry>, JournalError> {
        // Check re-entrancy before calling into JS
        let _guard = ReentryGuard::try_enter().map_err(JournalError::Other)?;

        // Convert DateTime<Utc> to milliseconds since epoch (JS uses ms timestamps)
        let since_ms = since.timestamp_millis() as f64;

        // Get the callback outside the async block (RefCell can't cross await)
        let cb = LOAD_ENTRIES_CALLBACK.with(|c| c.borrow().clone());
        let cb = cb.ok_or_else(|| {
            JournalError::Other(
                "loadEntries callback not set. Call setLoadEntriesCallback() before initChat()."
                    .to_string(),
            )
        })?;

        let this = JsValue::null();
        let arg = JsValue::from(since_ms);

        // Call the JS function — it returns a Promise (which we get as JsValue)
        let promise_val = cb
            .call1(&this, &arg)
            .map_err(|e| JournalError::Other(format!("loadEntries callback threw: {:?}", e)))?;

        let promise = js_sys::Promise::from(promise_val);
        let future = wasm_bindgen_futures::JsFuture::from(promise);

        let json_val = future
            .await
            .map_err(|e| JournalError::Other(format!("loadEntries callback rejected: {:?}", e)))?;

        let json_str: String = json_val.as_string().ok_or_else(|| {
            JournalError::Other(
                "loadEntries callback must return a string (JSON array of FileEntry)".to_string(),
            )
        })?;

        let entries: Vec<FileEntry> =
            serde_json::from_str(&json_str).map_err(|e| JournalError::Other(e.to_string()))?;

        Ok(entries)
    }
}

// ─── Setters ────────────────────────────────────────────────────────────────

/// Register a JS callback that loads file entries.
///
/// The callback receives a **millisecond** timestamp (Unix epoch) and must
/// **return a promise** that resolves to a JSON string — an array of
/// `{path, content, lastModified}` objects.
///
/// **⚠️ Re-entrancy:** The callback must **not** call back into any WASM
/// function that acquires the chat lock (e.g. `chatCompletion`,
/// `loadInitialContext`, `setApiKey`), or a
/// `"Re-entry detected"` error will be returned.
#[wasm_bindgen(js_name = setLoadEntriesCallback)]
pub fn wasm_set_load_entries_callback(cb: js_sys::Function) {
    LOAD_ENTRIES_CALLBACK.with(|f| *f.borrow_mut() = Some(cb));
}

/// Set the API key (e.g. DeepSeek). Must be called before `initChat`.
#[wasm_bindgen(js_name = setApiKey)]
pub fn wasm_set_api_key(key: &str) {
    let _ = API_KEY.set(key.to_string());
}

/// Set the API base URL. Defaults to `https://api.deepseek.com` if not set.
#[wasm_bindgen(js_name = setApiBase)]
pub fn wasm_set_api_base(base: &str) {
    let _ = API_BASE.set(base.to_string());
}



// ─── Chat initialisation ────────────────────────────────────────────────────

/// Initialise (or reset) the global Chat instance with the given model.
///
/// Must be called after `setApiKey` (and optionally `setApiBase` /
/// `setLoadEntriesCallback`). Calling this again
/// discards the previous conversation history.
///
/// The journal adapter uses the JS callback registered via
/// [`setLoadEntriesCallback`] — the callback must be set **before** this
/// function is called, or every `load_entries` call will fail.
#[wasm_bindgen(js_name = initChat)]
pub fn wasm_init_chat(model: &str) -> Result<(), JsError> {
    let api_key = API_KEY
        .get()
        .ok_or_else(|| JsError::new("API key not set. Call setApiKey() first."))?;

    let api_base = API_BASE
        .get()
        .map(|s| s.as_str())
        .unwrap_or("https://api.deepseek.com");

    let adapter = OpenAiAdapter::new(api_key.clone(), api_base.to_string(), model.to_string());

    let chat = Chat::new(
        Box::new(adapter),
        Box::new(WasmJournalAdapter),
        Box::new(quest_repository::WasmQuestRepository),
        Box::new(timeline_repository::WasmTimelineRepository),
    );

    let _ = CHAT.set(Mutex::new(chat));
    Ok(())
}

// ─── Initial context ────────────────────────────────────────────────────────

/// Load the initial document context from the journal.
///
/// This calls the JS `loadEntries` callback with the epoch timestamp, so
/// every file is returned. The YAML document is built from the result and
/// stored as the AI's reference context.
///
/// Must be called once after `initChat()` and before the first
/// `chatCompletion()`.
#[wasm_bindgen(js_name = loadInitialContext)]
pub async fn wasm_load_initial_context() -> Result<usize, JsError> {
    let chat_mutex = CHAT
        .get()
        .ok_or_else(|| JsError::new("Chat not initialised. Call initChat() first."))?;

    let mut chat = chat_mutex.lock().expect("Chat mutex poisoned");
    let count = chat.load_initial_context().await?;
    Ok(count)
}

// ─── Chat completion ────────────────────────────────────────────────────────

/// Send a chat completion request and return the assistant's reply.
///
/// The global Chat instance must have been initialised via `initChat()` first.
///
/// Before the API call, `loadEntries(since_last_check)` is called
/// automatically via the journal adapter's JS callback, so file changes
/// are detected and injected as update messages without any JS intervention.
///
/// @param {string} userMessage - the user's message to append
/// @param {string} userMessage - the user's message to append
/// @param {number} dayMs - milliseconds-since-epoch timestamp representing
///        the start of the calendar day to use for quest queries.
/// @returns {Promise<string>} JSON array of ChatMessage objects from this turn
#[wasm_bindgen(js_name = chatCompletion)]
pub async fn wasm_chat_completion(user_message: &str, day_ms: f64) -> Result<String, JsError> {
    let chat_mutex = CHAT
        .get()
        .ok_or_else(|| JsError::new("Chat not initialised. Call initChat() first."))?;

    let mut chat = chat_mutex.lock().expect("Chat mutex poisoned");

    let day = DateTime::from_timestamp_millis(day_ms as i64)
        .ok_or_else(|| JsError::new("Invalid day_ms timestamp"))?
        .date_naive();

    let messages = chat
        .user_message(user_message.to_string(), day)
        .await
        .map_err(|e| JsError::new(&e.to_string()))?;

    let json = serde_json::to_string(&messages)
        .map_err(|e| JsError::new(&e.to_string()))?;

    Ok(json)
}

// ─── Test mode ──────────────────────────────────────────────────────────────

/// Toggle test mode on the global Chat instance.
/// When enabled, the system prompt is replaced with a short override that tells
/// the LLM to obey without coaching pushback.
#[wasm_bindgen(js_name = setTestMode)]
pub fn wasm_set_test_mode(enabled: bool) -> Result<(), JsError> {
    let chat_mutex = CHAT
        .get()
        .ok_or_else(|| JsError::new("Chat not initialised. Call initChat() first."))?;

    let mut chat = chat_mutex.lock().expect("Chat mutex poisoned");
    chat.set_test_mode(enabled);
    Ok(())
}

// ─── Produce YAML ───────────────────────────────────────────────────────────

/// Produce a YAML document from a list of file entries.
///
/// Accepts a JSON string representing an array of `{path, content, lastModified}`.
/// Returns the YAML string.
///
/// This is kept as a utility for the JS side (e.g. logging).
#[wasm_bindgen(js_name = produceYaml)]
pub fn wasm_produce_yaml(files_json: &str) -> Result<String, JsError> {
    let files: Vec<FileEntry> =
        serde_json::from_str(files_json).map_err(|e| JsError::new(&e.to_string()))?;
    Ok(prompt_yourself_core::yaml_producer::produce_yaml(&files))
}

// ─── Game state ─────────────────────────────────────────────────────────────

/// Return the current quest game state (open quests, completed quests, total
/// points) as a JSON string.
///
/// Reads from the repository cache without locking the CHAT mutex,
/// so it can be called at any time without risk of deadlock.
#[wasm_bindgen(js_name = getGameState)]
pub async fn wasm_get_game_state() -> Result<String, JsError> {
    Ok(quest_repository::get_quest_state_from_cache().await)
}

