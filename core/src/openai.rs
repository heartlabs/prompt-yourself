//! OpenAI chat completion using async-openai-wasm.
//!
//! This module provides a minimal public API over the async-openai-wasm crate.
//! It does NOT leak async-openai types; consumers only see our own
//! [`Role`], [`ChatMessage`] and [`ChatError`].

use async_openai_wasm::{
    config::OpenAIConfig,
    types::chat::{
        ChatCompletionRequestAssistantMessage, ChatCompletionRequestAssistantMessageContent,
        ChatCompletionRequestMessage, ChatCompletionRequestSystemMessage,
        ChatCompletionRequestSystemMessageContent, ChatCompletionRequestUserMessage,
        ChatCompletionRequestUserMessageContent, CreateChatCompletionRequestArgs,
    },
    Client,
};
use serde::{Deserialize, Serialize};
use std::error::Error as _;

// ─── Public domain types ────────────────────────────────────────────────────

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

/// Error type for chat completion operations.
#[derive(Debug, thiserror::Error)]
pub enum ChatError {
    /// An error from the async-openai-wasm crate (HTTP-level failure).
    #[error("HTTP error: {0}")]
    Http(String),

    /// The API returned an error object with details.
    #[error("API error: {message}{}", .detail.as_deref().map(|d| format!(" ({d})")).unwrap_or_default())]
    Api {
        message: String,
        detail: Option<String>,
    },

    /// An error from the async-openai-wasm crate (other).
    #[error("{0}")]
    Other(String),
}

impl From<async_openai_wasm::error::OpenAIError> for ChatError {
    fn from(e: async_openai_wasm::error::OpenAIError) -> Self {
        match e {
            async_openai_wasm::error::OpenAIError::Reqwest(err) => {
                // Build a detailed message: status code (if available), error chain
                let mut detail = err.to_string();
                if let Some(status) = err.status() {
                    detail = format!("status {status}: {detail}");
                }
                // Append the full source chain (e.g. TLS, DNS, timeout)
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
                    ChatError::Other(format!("failed to parse API response: {}…", &content[..200]))
                } else {
                    ChatError::Other(format!("failed to parse API response: {content}"))
                }
            }
            other => ChatError::Other(other.to_string()),
        }
    }
}

// ─── Internal helpers ───────────────────────────────────────────────────────

/// Convert our public [`ChatMessage`] into async-openai's request message enum.
fn to_openai_messages(messages: Vec<ChatMessage>) -> Vec<ChatCompletionRequestMessage> {
    messages
        .into_iter()
        .map(|m| match m.role {
            Role::System => ChatCompletionRequestMessage::System(
                ChatCompletionRequestSystemMessage {
                    content: ChatCompletionRequestSystemMessageContent::Text(m.content),
                    name: None,
                },
            ),
            Role::User => ChatCompletionRequestMessage::User(ChatCompletionRequestUserMessage {
                content: ChatCompletionRequestUserMessageContent::Text(m.content),
                name: None,
            }),
            Role::Assistant => ChatCompletionRequestMessage::Assistant(
                ChatCompletionRequestAssistantMessage {
                    content: Some(ChatCompletionRequestAssistantMessageContent::Text(m.content)),
                    name: None,
                    ..Default::default()
                },
            ),
        })
        .collect()
}

// ─── Public API ─────────────────────────────────────────────────────────────

/// Send a chat completion request and return the assistant's reply text.
///
/// `api_key` is the API key (e.g. DeepSeek, OpenAI).
/// `base_url` is the API base URL (e.g. `"https://api.deepseek.com"`).
/// `model` is the model name (e.g. `"deepseek-chat"`).
pub async fn chat_completion(
    api_key: &str,
    base_url: &str,
    model: &str,
    messages: Vec<ChatMessage>,
    max_tokens: u32,
) -> Result<String, ChatError> {
    let config = OpenAIConfig::new()
        .with_api_key(api_key)
        .with_api_base(base_url);

    let client = Client::with_config(config);
    let openai_messages = to_openai_messages(messages);

    let request = CreateChatCompletionRequestArgs::default()
        .model(model)
        .messages(openai_messages)
        .max_completion_tokens(max_tokens)
        .build()?;

    let response = client.chat().create(request).await?;

    let content = response
        .choices
        .first()
        .and_then(|c| c.message.content.clone())
        .unwrap_or_default();

    Ok(content)
}
