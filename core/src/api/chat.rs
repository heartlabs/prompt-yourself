use chrono::{DateTime, Utc};

use crate::domain::entities::game::{GameService, Quest};
use crate::domain::ports::journal::JournalPort;
use crate::domain::ports::openai::{ChatError, ChatMessage, ChatResponse, OpenAiPort};
use crate::domain::tools;
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
    document_context: Option<ChatMessage>,
    system_prompt: String,
    openai_port: Box<dyn OpenAiPort>,
    journal: Box<dyn JournalPort>,
    /// Timestamp of the most recent check. Used as `since` parameter for the
    /// next `load_entries` call. Updated after every `user_message`.
    last_check_time: DateTime<Utc>,

    game_service: GameService,
}

impl Chat {
    /// Create a new chat session.
    ///
    /// `openai_port` — a fully configured driven-port adapter (e.g. `OpenAiAdapter`).
    /// `system_prompt` — the system prompt to use (default: [`SYSTEM_PROMPT`]).
    /// `journal` — a journal adapter; used to load the initial context and to
    ///             detect file changes before every API call.
    /// `game_service` — the quest game service (e.g. `GameService::new(…)`).
    pub fn new(
        openai_port: Box<dyn OpenAiPort>,
        system_prompt: String,
        journal: Box<dyn JournalPort>,
        game_service: GameService,
    ) -> Self {
        Self {
            history: Vec::new(),
            document_context: None,
            system_prompt,
            openai_port,
            journal,
            last_check_time: DateTime::UNIX_EPOCH,
            game_service,
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
        self.document_context = Some(ChatMessage::User {
            content: format!("Here is the document to reference:\n\n{yaml_content}"),
        });

        Ok(entries.len())
    }

    /// Set the last-check timestamp to the current time.
    fn stamp_now(&mut self) {
        self.last_check_time = Utc::now();
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

            self.history.push(ChatMessage::User { content: msg });
        }
    }

    /// Send a user message and return the new messages produced during this turn
    /// (assistant replies, tool notifications, etc.), in chronological order.
    ///
    /// Before making the API call, the journal is queried for entries modified
    /// since the last message. Any changes are injected as update notices into
    /// the conversation history so the AI always sees the latest file contents.
    ///
    /// If the model calls tools (e.g. quest tools), the tool calls are executed
    /// and their results are fed back into the conversation. This loop continues
    /// until the model produces a text reply, up to 5 iterations.
    pub async fn user_message(&mut self, content: String) -> Result<Vec<ChatMessage>, ChatError> {
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
        self.stamp_now();

        self.history.push(ChatMessage::User { content });

        let mut turn_messages: Vec<ChatMessage> = Vec::new();
        let max_iterations: u32 = 5;
        for _ in 0..max_iterations {
            // Build the full messages array: system prompt + document context + history
            let mut messages = vec![ChatMessage::System {
                content: self.system_prompt.clone(),
            }];
            if let Some(doc_msg) = &self.document_context {
                messages.push(doc_msg.clone());
            }
            messages.extend(self.history.clone());

            let response = self
                .openai_port
                .chat_completion_with_tools(
                    messages,
                    MAX_TOKENS,
                    tools::tool_definitions(),
                )
                .await?;

            match response {
                ChatResponse::Text(reply) => {
                    let msg = ChatMessage::Assistant {
                        content: Some(reply.clone()),
                        tool_calls: None,
                    };
                    self.history.push(msg.clone());
                    turn_messages.push(msg);
                    return Ok(turn_messages);
                }
                ChatResponse::ToolCalls {
                    content,
                    tool_calls,
                } => {
                    // Push assistant message that includes both text and tool calls
                    let msg = ChatMessage::Assistant {
                        content,
                        tool_calls: Some(tool_calls.clone()),
                    };
                    self.history.push(msg.clone());
                    turn_messages.push(msg);

                    // Execute each tool call
                    for call in &tool_calls {
                        let outcome = tools::execute(&mut self.game_service, call);

                        // Detailed message for the LLM (internal history only)
                        self.history.push(ChatMessage::Tool {
                            content: outcome.llm_message,
                            tool_call_id: outcome.tool_call_id.clone(),
                        });

                        // Concise message for the user (returned to expert)
                        turn_messages.push(ChatMessage::Tool {
                            content: outcome.user_message,
                            tool_call_id: outcome.tool_call_id,
                        });
                    }

                    // Continue the loop so the model can respond to tool results
                }
            }
        }

        Err(ChatError::Other(
            "Tool call loop exceeded maximum iterations".to_string(),
        ))
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

    pub fn open_quests(&self) -> Vec<Quest> {
        self.game_service.list_open_quests()
    }

    pub fn completed_quests(&self) -> Vec<Quest> {
        self.game_service.list_completed_quests()
    }

    pub fn game_points(&self) -> u32 {
        self.game_service.list_completed_quests().iter().map(|quest| quest.points).sum()
    }
}
