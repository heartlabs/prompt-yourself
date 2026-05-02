use serde::{Deserialize, Serialize};

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

/// Request body for the DeepSeek (OpenAI-compatible) chat completions endpoint.
#[derive(Debug, Clone, Serialize)]
pub struct ChatCompletionRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    pub max_tokens: u32,
}

/// A choice returned in the API response.
#[derive(Debug, Deserialize)]
pub struct Choice {
    pub message: ChatMessage,
}

/// Response body from the chat completions endpoint.
#[derive(Debug, Deserialize)]
pub struct ChatCompletionResponse {
    pub choices: Vec<Choice>,
}

impl ChatCompletionRequest {
    /// Create a new request for the DeepSeek model.
    pub fn new(messages: Vec<ChatMessage>, max_tokens: u32) -> Self {
        Self {
            model: "deepseek-chat".to_string(),
            messages,
            max_tokens,
        }
    }
}
