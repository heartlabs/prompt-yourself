//! Driven port for OpenAI-compatible chat completion.
//!
//! This module defines the [`OpenAiPort`] trait that the domain expects,
//! along with the shared types [`ChatMessage`], [`Role`], and [`ChatError`].

use serde::{Deserialize, Serialize};
use std::error::Error as _;

// ─── Port ───────────────────────────────────────────────────────────────────

/// Driven port for making chat completion requests to an OpenAI-compatible API.
///
/// Implementations are stateless — history management is handled by the caller.
/// Construction is outside the trait (see [`super::OpenAiAdapter`]).
///
/// When compiling for WASM (single-threaded), `Send` is not required.
/// Conditional async trait: on native targets (where multi-threading is possible) we require
/// the returned future to be Send; on WASM we do not, because the JS/WASM runtime is
/// single-threaded and many WASM types (Rc, JsValue, etc.) are !Send.
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
pub trait OpenAiPort: Send {
    /// Send a list of messages and return the assistant's reply text.
    async fn chat_completion(
        &self,
        messages: Vec<ChatMessage>,
        max_tokens: u32,
    ) -> Result<String, ChatError>;
}

// ─── Domain types ───────────────────────────────────────────────────────────

/// The role of a message participant.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
}

/// A single message in the chat conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: Role,
    pub content: String,
}

// ─── Error type ─────────────────────────────────────────────────────────────

/// Error type for chat completion operations.
#[derive(Debug, thiserror::Error)]
pub enum ChatError {
    /// An HTTP-level failure.
    #[error("HTTP error: {0}")]
    Http(String),

    /// The API returned an error object with details.
    #[error("API error: {message}{}", .detail.as_deref().map(|d| format!(" ({d})")).unwrap_or_default())]
    Api {
        message: String,
        detail: Option<String>,
    },

    /// Other errors (JSON parsing, etc.).
    #[error("{0}")]
    Other(String),
}

impl From<async_openai_wasm::error::OpenAIError> for ChatError {
    fn from(e: async_openai_wasm::error::OpenAIError) -> Self {
        match e {
            async_openai_wasm::error::OpenAIError::Reqwest(err) => {
                let mut detail = err.to_string();
                if let Some(status) = err.status() {
                    detail = format!("status {status}: {detail}");
                }
                let mut source = err.source();
                while let Some(s) = source {
                    detail = format!("{detail} -> {s}");
                    source = s.source();
                }
                ChatError::Http(detail)
            }
            async_openai_wasm::error::OpenAIError::ApiError(api_err) => {
                let detail = match (&api_err.r#type, &api_err.param, &api_err.code) {
                    (Some(t), _, _) if !t.is_empty() => Some(t.clone()),
                    (_, Some(p), _) if !p.is_empty() => Some(format!("param: {p}")),
                    (_, _, Some(c)) if !c.is_empty() => Some(format!("code: {c}")),
                    _ => None,
                };
                ChatError::Api {
                    message: api_err.message,
                    detail,
                }
            }
            async_openai_wasm::error::OpenAIError::JSONDeserialize(_, content) => {
                if content.len() > 200 {
                    ChatError::Other(format!(
                        "failed to parse API response: {}…",
                        &content[..200]
                    ))
                } else {
                    ChatError::Other(format!("failed to parse API response: {content}"))
                }
            }
            other => ChatError::Other(other.to_string()),
        }
    }
}
