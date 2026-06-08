//! OpenAI chat completion adapter.
//!
//! Provides [`OpenAiAdapter`], the single [`OpenAiPort`] implementation shared
//! by both the CLI and WASM targets.

use async_openai_wasm::{
    config::OpenAIConfig,
    types::chat::{
        ChatCompletionMessageToolCall, ChatCompletionMessageToolCalls,
        ChatCompletionRequestAssistantMessage, ChatCompletionRequestAssistantMessageContent,
        ChatCompletionRequestMessage, ChatCompletionRequestSystemMessage,
        ChatCompletionRequestSystemMessageContent, ChatCompletionRequestToolMessage,
        ChatCompletionRequestToolMessageContent, ChatCompletionRequestUserMessage,
        ChatCompletionRequestUserMessageContent, ChatCompletionTool, ChatCompletionTools,
        CreateChatCompletionRequestArgs, FunctionCall, FunctionObject,
    },
    Client,
};

use crate::domain::ports::openai::{ChatError, ChatMessage, ChatResponse, OpenAiPort, ToolCall, ToolDefinition, UsageInfo};

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
    async fn chat_completion_with_tools(
        &self,
        messages: Vec<ChatMessage>,
        max_tokens: u32,
        tools: Vec<ToolDefinition>,
    ) -> Result<(ChatResponse, UsageInfo), ChatError> {
        let config = OpenAIConfig::new()
            .with_api_key(&self.api_key)
            .with_api_base(&self.api_base_url);

        let client = Client::with_config(config);
        let openai_messages = to_openai_messages(messages);
        let openai_tools = to_openai_tools(tools);

        let mut request_builder = CreateChatCompletionRequestArgs::default();
        request_builder.model(&self.model);
        request_builder.messages(openai_messages);
        request_builder.max_completion_tokens(max_tokens);

        if !openai_tools.is_empty() {
            request_builder.tools(openai_tools);
        }

        let request = request_builder.build()?;

        let response = client.chat().create(request).await?;

        let usage = extract_usage(response.usage.as_ref());

        let choice = response.choices.first().ok_or_else(|| {
            ChatError::Other("No choices returned from OpenAI API".to_string())
        })?;

        let message = &choice.message;
        let content = message.content.clone();

        if let Some(tool_calls) = &message.tool_calls {
            let calls: Vec<ToolCall> = tool_calls
                .iter()
                .filter_map(|tc| match tc {
                    ChatCompletionMessageToolCalls::Function(f) => Some(ToolCall {
                        id: f.id.clone(),
                        name: f.function.name.clone(),
                        arguments: f.function.arguments.clone(),
                    }),
                    _ => None,
                })
                .collect();

            if !calls.is_empty() {
                return Ok((ChatResponse::ToolCalls { content, tool_calls: calls }, usage));
            }
        }

        Ok((ChatResponse::Text(content.unwrap_or_default()), usage))
    }
}

// ─── Internal helpers ───────────────────────────────────────────────────────

/// Extract [`UsageInfo`] from the API response's optional usage field.
fn extract_usage(usage: Option<&async_openai_wasm::types::chat::CompletionUsage>) -> UsageInfo {
    usage
        .map(|u| UsageInfo {
            prompt_tokens: u.prompt_tokens,
            completion_tokens: u.completion_tokens,
            total_tokens: u.total_tokens,
            cached_tokens: u
                .prompt_tokens_details
                .as_ref()
                .and_then(|d| d.cached_tokens),
            reasoning_tokens: u
                .completion_tokens_details
                .as_ref()
                .and_then(|d| d.reasoning_tokens),
        })
        .unwrap_or_default()
}

/// Convert our domain [`ChatMessage`] into async-openai's request message enum.
fn to_openai_messages(messages: Vec<ChatMessage>) -> Vec<ChatCompletionRequestMessage> {
    messages
        .into_iter()
        .map(|m| match m {
            ChatMessage::System { content } => {
                ChatCompletionRequestMessage::System(ChatCompletionRequestSystemMessage {
                    content: ChatCompletionRequestSystemMessageContent::Text(content),
                    name: None,
                })
            }
            ChatMessage::User { content } => {
                ChatCompletionRequestMessage::User(ChatCompletionRequestUserMessage {
                    content: ChatCompletionRequestUserMessageContent::Text(content),
                    name: None,
                })
            }
            ChatMessage::Assistant {
                content,
                tool_calls,
            } => {
                let tool_calls = tool_calls.map(|calls| {
                    calls
                        .into_iter()
                        .map(|call| {
                            ChatCompletionMessageToolCalls::Function(
                                ChatCompletionMessageToolCall {
                                    id: call.id,
                                    function: FunctionCall {
                                        name: call.name,
                                        arguments: call.arguments,
                                    },
                                },
                            )
                        })
                        .collect()
                });
                ChatCompletionRequestMessage::Assistant(ChatCompletionRequestAssistantMessage {
                    content: content.map(ChatCompletionRequestAssistantMessageContent::Text),
                    name: None,
                    tool_calls,
                    ..Default::default()
                })
            }
            ChatMessage::Tool {
                content,
                tool_call_id,
            } => {
                ChatCompletionRequestMessage::Tool(ChatCompletionRequestToolMessage {
                    content: ChatCompletionRequestToolMessageContent::Text(content),
                    tool_call_id,
                })
            }
        })
        .collect()
}

/// Convert our domain [`ToolDefinition`] into async-openai's tool definition enum.
fn to_openai_tools(tools: Vec<ToolDefinition>) -> Vec<ChatCompletionTools> {
    tools
        .into_iter()
        .map(|t| {
            ChatCompletionTools::Function(ChatCompletionTool {
                function: FunctionObject {
                    name: t.name,
                    description: Some(t.description),
                    parameters: Some(t.parameters),
                    strict: None,
                },
            })
        })
        .collect()
}
