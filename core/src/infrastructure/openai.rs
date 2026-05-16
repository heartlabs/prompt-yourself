//! OpenAI chat completion adapter.
//!
//! Provides [`OpenAiAdapter`], the single [`OpenAiPort`] implementation shared
//! by both the CLI and WASM targets.

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

use crate::domain::ports::openai::{ChatError, ChatMessage, OpenAiPort, Role};

// ─── Adapter ────────────────────────────────────────────────────────────────

/// Adapter that calls an OpenAI-compatible API via `async-openai-wasm`.
pub struct OpenAiAdapter {
    api_key: String,
    api_base_url: String,
    model: String,
}

impl OpenAiAdapter {
    pub fn new(api_key: String, api_base_url: String, model: String) -> Self {
        Self {
            api_key,
            api_base_url,
            model,
        }
    }
}

#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
impl OpenAiPort for OpenAiAdapter {
    async fn chat_completion(
        &self,
        messages: Vec<ChatMessage>,
        max_tokens: u32,
    ) -> Result<String, ChatError> {
        let config = OpenAIConfig::new()
            .with_api_key(&self.api_key)
            .with_api_base(&self.api_base_url);

        let client = Client::with_config(config);
        let openai_messages = to_openai_messages(messages);

        let request = CreateChatCompletionRequestArgs::default()
            .model(&self.model)
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
}

// ─── Internal helpers ───────────────────────────────────────────────────────

/// Convert our domain [`ChatMessage`] into async-openai's request message enum.
fn to_openai_messages(messages: Vec<ChatMessage>) -> Vec<ChatCompletionRequestMessage> {
    messages
        .into_iter()
        .map(|m| match m.role {
            Role::System => {
                ChatCompletionRequestMessage::System(ChatCompletionRequestSystemMessage {
                    content: ChatCompletionRequestSystemMessageContent::Text(m.content),
                    name: None,
                })
            }
            Role::User => ChatCompletionRequestMessage::User(ChatCompletionRequestUserMessage {
                content: ChatCompletionRequestUserMessageContent::Text(m.content),
                name: None,
            }),
            Role::Assistant => {
                ChatCompletionRequestMessage::Assistant(ChatCompletionRequestAssistantMessage {
                    content: Some(ChatCompletionRequestAssistantMessageContent::Text(
                        m.content,
                    )),
                    name: None,
                    ..Default::default()
                })
            }
        })
        .collect()
}
