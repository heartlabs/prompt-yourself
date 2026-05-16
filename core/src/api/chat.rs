use crate::domain::ports::openai::{ChatError, ChatMessage, OpenAiPort, Role};

pub const SYSTEM_PROMPT: &str = include_str!("../../resources/system-prompt.md");
const MAX_TOKENS: u32 = 500;

// ─── Driving port ───────────────────────────────────────────────────────────

/// Main entry point for chat interactions.
///
/// Manages conversation history and delegates actual API calls to an
/// [`OpenAiPort`] implementation.
pub struct Chat {
    history: Vec<ChatMessage>,
    /// The document context (the YAML journal) is stored separately from `history`
    /// so it survives `reset()` calls. It is injected as the first user message
    /// after the system prompt in every API call.
    document_context: Option<ChatMessage>,
    system_prompt: String,
    openai_port: Box<dyn OpenAiPort>,
}

impl Chat {
    /// Create a new chat session.
    ///
    /// `openai_port` — a fully configured driven-port adapter (e.g. `OpenAiAdapter`).
    /// `system_prompt` — the system prompt to use (default: [`SYSTEM_PROMPT`]).
    pub fn new(openai_port: Box<dyn OpenAiPort>, system_prompt: String) -> Self {
        Self {
            history: Vec::new(),
            document_context: None,
            system_prompt,
            openai_port,
        }
    }

    /// Set the document context (the YAML journal) that the AI should reference.
    ///
    /// This is stored as a user message that follows the system prompt in every API call.
    /// Unlike `history`, it is **not** cleared by `reset()`, so the AI always has access
    /// to the journal regardless of conversation resets.
    pub fn set_document_context(&mut self, yaml_content: &str) {
        self.document_context = Some(ChatMessage {
            role: Role::User,
            content: format!("Here is the document to reference:\n\n{yaml_content}"),
        });
    }

    /// Reset the conversation history, keeping the system prompt and document context.
    pub fn reset(&mut self) {
        self.history.clear();
    }

    /// Send a user message and return the assistant's reply.
    ///
    /// The message is appended to history, the full conversation (system prompt +
    /// document context + history) is sent to the API, and the assistant's reply
    /// is appended to history before being returned.
    pub async fn user_message(&mut self, content: String) -> Result<String, ChatError> {
        self.history.push(ChatMessage {
            role: Role::User,
            content,
        });

        // Build the full messages array: system prompt + document context + history
        let mut messages = vec![ChatMessage {
            role: Role::System,
            content: self.system_prompt.clone(),
        }];
        if let Some(doc_msg) = &self.document_context {
            messages.push(doc_msg.clone());
        }
        messages.extend(self.history.clone());

        let reply = self
            .openai_port
            .chat_completion(messages, MAX_TOKENS)
            .await?;

        self.history.push(ChatMessage {
            role: Role::Assistant,
            content: reply.clone(),
        });

        Ok(reply)
    }

    /// Return a reference to the full conversation (not including the document context).
    pub fn history(&self) -> &[ChatMessage] {
        &self.history
    }

    /// Return a reference to the document context message, if set.
    pub fn document_context(&self) -> Option<&ChatMessage> {
        self.document_context.as_ref()
    }
}
