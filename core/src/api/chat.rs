use chrono::{DateTime, Utc};

use crate::domain::ports::journal::JournalPort;
use crate::domain::ports::openai::{ChatError, ChatMessage, OpenAiPort, Role};
use crate::yaml_producer::FileEntry;

pub const SYSTEM_PROMPT: &str = include_str!("../../resources/system-prompt.md");
const MAX_TOKENS: u32 = 500;

// ─── Driving port ───────────────────────────────────────────────────────────

/// Main entry point for chat interactions.
///
/// Manages conversation history and delegates actual API calls to an
/// [`OpenAiPort`] implementation.
///
/// A [`JournalPort`] is required — it is used both for the initial load
/// (building the YAML document context) and for incremental change detection
/// before every `user_message`.  The trait is async so that WASM adapters
/// can delegate to a JS callback.
pub struct Chat {
    history: Vec<ChatMessage>,
    /// The document context (the YAML journal) is stored separately from `history`
    /// so it survives `reset()` calls. It is injected as the first user message
    /// after the system prompt in every API call.
    document_context: Option<ChatMessage>,
    system_prompt: String,
    openai_port: Box<dyn OpenAiPort>,
    journal: Box<dyn JournalPort>,
    /// Timestamp of the most recent check. Used as `since` parameter for the
    /// next `load_entries` call. Updated after every `user_message`.
    last_check_time: DateTime<Utc>,
}

impl Chat {
    /// Create a new chat session.
    ///
    /// `openai_port` — a fully configured driven-port adapter (e.g. `OpenAiAdapter`).
    /// `system_prompt` — the system prompt to use (default: [`SYSTEM_PROMPT`]).
    /// `journal` — a journal adapter; used to load the initial context and to
    ///             detect file changes before every API call.
    pub fn new(
        openai_port: Box<dyn OpenAiPort>,
        system_prompt: String,
        journal: Box<dyn JournalPort>,
    ) -> Self {
        Self {
            history: Vec::new(),
            document_context: None,
            system_prompt,
            openai_port,
            journal,
            last_check_time: DateTime::UNIX_EPOCH,
        }
    }

    /// Load the initial document context from the journal and seed the AI context.
    ///
    /// Must be called before the first `user_message`. Returns the number of files
    /// loaded.
    pub async fn load_initial_context(&mut self) -> Result<usize, ChatError> {
        let entries = self
            .journal
            .load_entries(&self.last_check_time)
            .await
            .map_err(|e| ChatError::Other(format!("Failed to load journal: {e}")))?;

        let yaml_content = crate::yaml_producer::produce_yaml(&entries);
        self.document_context = Some(ChatMessage {
            role: Role::User,
            content: format!("Here is the document to reference:\n\n{yaml_content}"),
        });

        Ok(entries.len())
    }

    /// Set the last-check timestamp to the current time.
    fn stamp_now(&mut self) {
        self.last_check_time = Utc::now();
    }

    /// Reset the conversation history, keeping the system prompt and document context.
    pub fn reset(&mut self) {
        self.history.clear();
    }

    /// Inject file updates into the conversation history.
    ///
    /// Each updated file produces a user message in the form:
    ///   Note: File <path> was updated at <timestamp>. New file content:
    ///   <content>
    fn inject_updates(&mut self, updates: Vec<FileEntry>) {
        for entry in updates {
            let path = &entry.path;
            let timestamp = entry
                .last_modified
                .as_ref()
                .map(|ts| ts.to_rfc3339())
                .unwrap_or_else(|| "unknown time".to_string());

            let msg = match &entry.content {
                Some(content) => format!(
                    "Note: File {path} was updated at {timestamp}. New file content:\n\n{content}"
                ),
                None => format!("Note: File {path} was updated at {timestamp}."),
            };

            self.history.push(ChatMessage {
                role: Role::User,
                content: msg,
            });
        }
    }

    /// Send a user message and return the assistant's reply.
    ///
    /// Before making the API call, the journal is queried for entries modified
    /// since the last message. Any changes are injected as update notices into
    /// the conversation history so the AI always sees the latest file contents.
    pub async fn user_message(&mut self, content: String) -> Result<String, ChatError> {
        // ── Check for file updates since the last check ─────────────────
        match self.journal.load_entries(&self.last_check_time).await {
            Ok(updates) if !updates.is_empty() => {
                self.inject_updates(updates);
            }
            Ok(_) => { /* no changes */ }
            Err(e) => {
                eprintln!("Warning: failed to check for file updates: {e}");
            }
        }
        // Stamp the current time *after* loading updates but *before* the
        // API call, so the next check catches anything modified during this
        // conversation turn.
        self.stamp_now();

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

    /// Return a reference to the last check time.
    pub fn last_check_time(&self) -> &DateTime<Utc> {
        &self.last_check_time
    }
}
