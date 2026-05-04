pub mod openai;
pub mod yaml_producer;

/// The system prompt packaged at compile time.
pub const SYSTEM_PROMPT: &str = include_str!("../resources/system-prompt.md");

/// Build the initial messages array: system prompt + the document content.
pub fn build_initial_messages(document_content: &str) -> Vec<openai::ChatMessage> {
    vec![
        openai::ChatMessage {
            role: openai::Role::System,
            content: SYSTEM_PROMPT.to_string(),
        },
        openai::ChatMessage {
            role: openai::Role::User,
            content: format!("Here is the document to reference:\n\n{document_content}"),
        },
    ]
}

