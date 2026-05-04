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

use std::sync::OnceLock;

use prompt_yourself_core::openai::ChatMessage;
use prompt_yourself_core::yaml_producer::{produce_yaml, FileEntry};
use wasm_bindgen::prelude::*;

// ─── Global state ───────────────────────────────────────────────────────────

static API_KEY: OnceLock<String> = OnceLock::new();
static API_BASE: OnceLock<String> = OnceLock::new();
static SYSTEM_PROMPT: OnceLock<String> = OnceLock::new();

/// Set the API key (e.g. DeepSeek). Must be called before `chatCompletion`.
#[wasm_bindgen(js_name = setApiKey)]
pub fn wasm_set_api_key(key: &str) {
    let _ = API_KEY.set(key.to_string());
}

/// Set the API base URL. Defaults to `https://api.deepseek.com` if not set.
#[wasm_bindgen(js_name = setApiBase)]
pub fn wasm_set_api_base(base: &str) {
    let _ = API_BASE.set(base.to_string());
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

// ─── Build initial messages ─────────────────────────────────────────────────

/// Set the system prompt (overrides the compiled-in default).
#[wasm_bindgen(js_name = setSystemPrompt)]
pub fn wasm_set_system_prompt(prompt: &str) {
    let _ = SYSTEM_PROMPT.set(prompt.to_string());
}

/// Build the initial messages array (system + user with the document).
/// Uses the override set by `setSystemPrompt` if available, otherwise the compiled-in prompt.
/// Returns a JSON string representing the messages array.
#[wasm_bindgen(js_name = buildInitialMessages)]
pub fn wasm_build_initial_messages(document_content: &str) -> String {
    let prompt = SYSTEM_PROMPT.get().map(|s| s.as_str()).unwrap_or(prompt_yourself_core::SYSTEM_PROMPT);
    let messages = prompt_yourself_core::build_initial_messages_with_prompt(document_content, prompt);
    serde_json::to_string(&messages).unwrap_or_else(|_| "[]".to_string())
}

// ─── Chat completion ────────────────────────────────────────────────────────

/// Send a chat completion request and return the assistant's reply.
///
/// @param {string} messagesJson - JSON string of the messages array
/// @param {number} maxTokens - maximum tokens in the response
/// @returns {Promise<string>}
#[wasm_bindgen(js_name = chatCompletion)]
pub async fn wasm_chat_completion(messages_json: &str, max_tokens: u32) -> Result<String, JsError> {
    let api_key = API_KEY.get().ok_or_else(|| {
        JsError::new("API key not set. Call setApiKey() first.")
    })?;

    let api_base = API_BASE
        .get()
        .map(|s| s.as_str())
        .unwrap_or("https://api.deepseek.com");

    let messages: Vec<ChatMessage> = serde_json::from_str(messages_json)
        .map_err(|e| JsError::new(&format!("Invalid messages JSON: {e}")))?;

    let reply = prompt_yourself_core::openai::chat_completion(
        api_key,
        api_base,
        "deepseek-chat",
        messages,
        max_tokens,
    )
    .await
    .map_err(|e| JsError::new(&e.to_string()))?;

    Ok(reply)
}
