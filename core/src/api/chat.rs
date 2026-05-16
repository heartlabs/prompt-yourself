use crate::domain::ports::journal::JournalPort;
use crate::domain::ports::openai::{ChatError, ChatMessage, OpenAiPort, Role};
use crate::yaml_producer::FileEntry;

pub const SYSTEM_PROMPT: &str = include_str!("../../resources/system-prompt.md");
const MAX_TOKENS: u32 = 500;

/// The lowest possible ISO 8601 timestamp, used to load *all* entries on first call.
pub const EPOCH: &str = "1970-01-01T00:00:00Z";

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
    /// ISO 8601 timestamp of the most recent check. Used as `since` parameter
    /// for the next `load_entries` call. Updated after every `user_message`.
    last_check_time: String,
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
            last_check_time: EPOCH.to_string(),
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
        let now = web_time::SystemTime::now()
            .duration_since(web_time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        self.last_check_time = format_iso8601(now);
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
            let timestamp = if entry.last_modified.is_empty() {
                "unknown time".to_string()
            } else {
                entry.last_modified.clone()
            };

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
}

/// Format Unix seconds as an ISO 8601 UTC string.
fn format_iso8601(unix_seconds: f64) -> String {
    let total_secs = unix_seconds as u64;
    let days = total_secs / 86400;
    let time_secs = total_secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    let mut y = 1970i64;
    let mut remaining = days as i64;
    loop {
        let days_in_year = if is_leap(y) { 366 } else { 365 };
        if remaining < days_in_year {
            break;
        }
        remaining -= days_in_year;
        y += 1;
    }
    let month_days = if is_leap(y) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m = 0usize;
    for (i, &md) in month_days.iter().enumerate() {
        if remaining < md as i64 {
            m = i;
            break;
        }
        remaining -= md as i64;
    }
    let d = remaining + 1;

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m + 1,
        d,
        hours,
        minutes,
        seconds
    )
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}
