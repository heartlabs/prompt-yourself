use async_trait::async_trait;

use crate::openai::{ChatCompletionRequest, ChatMessage};

/// Error type for chat completion operations.
#[derive(Debug, thiserror::Error)]
pub enum ChatError {
    #[error("API error ({status}): {body}")]
    ApiError { status: u16, body: String },

    #[error("HTTP error: {0}")]
    HttpError(String),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),
}

/// Abstract trait for an OpenAI-compatible chat completion API.
///
/// Platform-specific implementations (native HTTP vs WASM fetch) implement this
/// trait with their respective HTTP backends.
#[async_trait(?Send)]
pub trait OpenAIClient {
    /// Send a chat completion request and return the assistant's reply text.
    async fn chat_completion(
        &self,
        request: ChatCompletionRequest,
    ) -> Result<String, ChatError>;

    /// Convenience: send messages with a default max_tokens of 1000.
    async fn chat(
        &self,
        messages: Vec<ChatMessage>,
        max_tokens: u32,
    ) -> Result<String, ChatError> {
        let request = ChatCompletionRequest::new(messages, max_tokens);
        self.chat_completion(request).await
    }
}
