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

use prompt_yourself_core::client::{ChatError, OpenAIClient};
use prompt_yourself_core::openai::{ChatCompletionRequest, ChatMessage};
use prompt_yourself_core::yaml_producer::{produce_yaml, FileEntry};
use prompt_yourself_core::build_initial_messages;
use wasm_bindgen::prelude::*;

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

/// Build the initial messages array (system + user with the document).
/// Returns a JSON string representing the messages array.
#[wasm_bindgen(js_name = buildInitialMessages)]
pub fn wasm_build_initial_messages(document_content: &str) -> String {
    let messages = build_initial_messages(document_content);
    serde_json::to_string(&messages).unwrap_or_else(|_| "[]".to_string())
}

// ─── Chat completion (web-sys fetch) ────────────────────────────────────────

/// Global state for the API key (set once at plugin init).
static API_KEY: OnceLock<String> = OnceLock::new();

/// Set the DeepSeek API key. Must be called before `chatCompletion`.
#[wasm_bindgen(js_name = setApiKey)]
pub fn wasm_set_api_key(key: &str) {
    let _ = API_KEY.set(key.to_string());
}

/// A WASM-compatible HTTP client using `web_sys::fetch`.
struct WasmFetchClient;

#[async_trait::async_trait(?Send)]
impl OpenAIClient for WasmFetchClient {
    async fn chat_completion(
        &self,
        request: ChatCompletionRequest,
    ) -> Result<String, ChatError> {
        let api_key = API_KEY.get().ok_or_else(|| {
            ChatError::HttpError("API key not set. Call setApiKey() first.".to_string())
        })?;

        let body = serde_json::to_string(&request)
            .map_err(|e| ChatError::HttpError(e.to_string()))?;

        let opts = web_sys::RequestInit::new();
        opts.set_method("POST");
        opts.set_body(&wasm_bindgen::JsValue::from_str(&body));
        opts.set_mode(web_sys::RequestMode::Cors);

        let url = "https://api.deepseek.com/chat/completions";

        let request_obj = web_sys::Request::new_with_str_and_init(url, &opts)
            .map_err(|e| ChatError::HttpError(format!("Failed to create request: {:?}", e)))?;

        request_obj
            .headers()
            .set("Content-Type", "application/json")
            .map_err(|e| ChatError::HttpError(format!("Failed to set header: {:?}", e)))?;
        request_obj
            .headers()
            .set("Authorization", &format!("Bearer {api_key}"))
            .map_err(|e| ChatError::HttpError(format!("Failed to set header: {:?}", e)))?;

        let window = web_sys::window().ok_or_else(|| {
            ChatError::HttpError("No global `window` object found".to_string())
        })?;

        let promise = window.fetch_with_request(&request_obj);
        let response = wasm_bindgen_futures::JsFuture::from(promise)
            .await
            .map_err(|e| ChatError::HttpError(format!("Fetch failed: {:?}", e)))?;

        let response: web_sys::Response = response
            .dyn_into()
            .map_err(|_| ChatError::HttpError("Failed to cast response".to_string()))?;

        if !response.ok() {
            let status = response.status();
            let body_promise = response
                .text()
                .map_err(|e| ChatError::HttpError(format!("Failed to read response: {:?}", e)))?;
            let body = wasm_bindgen_futures::JsFuture::from(body_promise)
                .await
                .map_err(|e| ChatError::HttpError(format!("Failed to read body: {:?}", e)))?;
            let body_str: String = body.as_string().unwrap_or_default();
            return Err(ChatError::ApiError { status, body: body_str });
        }

        let body_promise = response
            .text()
            .map_err(|e| ChatError::HttpError(format!("Failed to read response: {:?}", e)))?;
        let body = wasm_bindgen_futures::JsFuture::from(body_promise)
            .await
            .map_err(|e| ChatError::HttpError(format!("Failed to read body: {:?}", e)))?;
        let body_str: String = body.as_string().unwrap_or_default();

        let data: prompt_yourself_core::openai::ChatCompletionResponse =
            serde_json::from_str(&body_str)
                .map_err(|e| ChatError::HttpError(format!("JSON parse error: {e}")))?;

        Ok(data.choices[0].message.content.clone())
    }
}

/// Send a chat completion request and return the assistant's reply.
///
/// @param {string} messagesJson - JSON string of the messages array
/// @param {number} maxTokens - maximum tokens in the response
/// @returns {Promise<string>}
#[wasm_bindgen(js_name = chatCompletion)]
pub async fn wasm_chat_completion(messages_json: &str, max_tokens: u32) -> Result<String, JsError> {
    let messages: Vec<ChatMessage> = serde_json::from_str(messages_json)
        .map_err(|e| JsError::new(&format!("Invalid messages JSON: {e}")))?;

    let client = WasmFetchClient;
    let reply = client
        .chat(messages, max_tokens)
        .await
        .map_err(|e| JsError::new(&e.to_string()))?;
    Ok(reply)
}
