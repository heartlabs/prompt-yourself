//! # WASM bindings for prompt-yourself-core
//!
//! This crate provides `#[wasm_bindgen]` exports that wrap the domain logic
//! in `prompt-yourself-core` for consumption from JavaScript (e.g., the Obsidian plugin).
//!
//! ## Alternatives considered
//!
//! Instead of a separate `core-wasm` crate, we considered compiling the `core` crate
//! directly with `--target wasm32-unknown-unknown`. The separate crate approach was chosen
//! to keep WASM-specific dependencies (`wasm-bindgen`, `web-sys`, `js-sys`) isolated from
//! the pure domain logic.
//!
//! If in the future we want to simplify the build pipeline, we could merge this logic
//! back into `core` behind a `#[cfg(target_arch = "wasm32")]` gate.
//!
//! ## Runtime WASM loading (alternative to bundling)
//!
//! Currently the Obsidian plugin bundles this WASM via esbuild. An alternative approach
//! would be dynamic `import()` at runtime in the plugin:
//!
//! ```js
//! // Inside Obsidian plugin's onload():
//! const wasm = await import('./core_wasm.js');
//! wasm.init(); // or the module auto-initializes
//! ```
//!
//! Pros of dynamic import: no build step for the plugin, lazy loading.
//! Cons: async init can be flaky across Obsidian versions, need to handle init failures,
//! must ship two extra files (glue .js + .wasm) alongside main.js.

use std::sync::{Mutex, OnceLock};

use prompt_yourself_core::{
    api::chat::Chat,
    yaml_producer::{produce_yaml, FileEntry},
    OpenAiAdapter,
};
use wasm_bindgen::prelude::*;

// ─── Global state ───────────────────────────────────────────────────────────

static API_KEY: OnceLock<String> = OnceLock::new();
static API_BASE: OnceLock<String> = OnceLock::new();
static SYSTEM_PROMPT: OnceLock<String> = OnceLock::new();
static CHAT: OnceLock<Mutex<Chat>> = OnceLock::new();

// ─── Setters ────────────────────────────────────────────────────────────────

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

/// Set the system prompt (overrides the compiled-in default).
#[wasm_bindgen(js_name = setSystemPrompt)]
pub fn wasm_set_system_prompt(prompt: &str) {
    let _ = SYSTEM_PROMPT.set(prompt.to_string());
}

// ─── Chat initialisation ────────────────────────────────────────────────────

/// Initialise (or reset) the global Chat instance with the given model.
///
/// Must be called after `setApiKey` (and optionally `setApiBase` / `setSystemPrompt`).
/// Calling this again discards the previous conversation history.
#[wasm_bindgen(js_name = initChat)]
pub fn wasm_init_chat(model: &str) -> Result<(), JsError> {
    let api_key = API_KEY
        .get()
        .ok_or_else(|| JsError::new("API key not set. Call setApiKey() first."))?;

    let api_base = API_BASE
        .get()
        .map(|s| s.as_str())
        .unwrap_or("https://api.deepseek.com");

    let system_prompt = SYSTEM_PROMPT
        .get()
        .map(|s| s.as_str())
        .unwrap_or(prompt_yourself_core::api::chat::SYSTEM_PROMPT);

    let adapter = OpenAiAdapter::new(api_key.clone(), api_base.to_string(), model.to_string());

    let chat = Chat::new(Box::new(adapter), system_prompt.to_owned());

    // Replace the existing chat if any, or set for the first time.
    let _ = CHAT.set(Mutex::new(chat));
    Ok(())
}

// ─── Produce YAML ───────────────────────────────────────────────────────────

/// Produce a YAML document from a list of file entries.
///
/// Accepts a JSON string representing an array of `{path: string, content: string | null}`.
/// Returns the YAML string.
#[wasm_bindgen(js_name = produceYaml)]
pub fn wasm_produce_yaml(files_json: &str) -> Result<String, JsError> {
    let files: Vec<FileEntry> =
        serde_json::from_str(files_json).map_err(|e| JsError::new(&e.to_string()))?;
    Ok(produce_yaml(&files))
}

// ─── Chat completion ────────────────────────────────────────────────────────

/// Send a chat completion request and return the assistant's reply.
///
/// The global Chat instance must have been initialised via `initChat()` first.
///
/// @param {string} userMessage - the user's message to append
/// @returns {Promise<string>}
#[wasm_bindgen(js_name = chatCompletion)]
pub async fn wasm_chat_completion(user_message: &str) -> Result<String, JsError> {
    let chat_mutex = CHAT
        .get()
        .ok_or_else(|| JsError::new("Chat not initialised. Call initChat() first."))?;

    let mut chat = chat_mutex.lock().expect("Chat mutex poisoned");

    let reply = chat
        .user_message(user_message.to_string())
        .await
        .map_err(|e| JsError::new(&e.to_string()))?;

    Ok(reply)
}

/// Set the document context (YAML journal) that the AI will reference.
///
/// Call this after `initChat()` and before the first `chatCompletion()`.
/// The context persists across `resetChat()` calls, so the AI always has
/// access to the journal regardless of conversation resets.
#[wasm_bindgen(js_name = setDocumentContext)]
pub fn wasm_set_document_context(yaml_content: &str) -> Result<(), JsError> {
    let chat_mutex = CHAT
        .get()
        .ok_or_else(|| JsError::new("Chat not initialised. Call initChat() first."))?;

    let mut chat = chat_mutex.lock().expect("Chat mutex poisoned");
    chat.set_document_context(yaml_content);
    Ok(())
}

/// Reset the conversation history so the next `chatCompletion` starts fresh.
///
/// Keeps the same API key, base URL, model, system prompt and document context.
#[wasm_bindgen(js_name = resetChat)]
pub fn wasm_reset_chat() {
    if let Some(chat_mutex) = CHAT.get() {
        if let Ok(mut chat) = chat_mutex.lock() {
            chat.reset();
        }
    }
}
