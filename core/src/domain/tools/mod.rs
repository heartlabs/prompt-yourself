//! Tool executor for LLM function calling.
//!
//! Defines the available tools (currently quest-related) and the [`execute`]
//! function that dispatches tool calls against the domain entities.

use serde::Deserialize;
use serde_json::json;

use crate::domain::entities::game::{Game, Quest};
use crate::domain::ports::openai::{ToolCall, ToolDefinition};

/// The outcome of executing a single tool call.
pub struct ToolOutcome {
    pub tool_call_id: String,
    pub message: String,
}

/// Returns the tool definitions for all available tools.
///
/// These are sent to the API so the model knows what it can call.
pub fn tool_definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: "register_quest".to_string(),
            description: "Register a new quest for the user to work toward. \
                          Call this when the user asks for a new quest or when \
                          you want to create one for them."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "A short, catchy title for the quest"
                    },
                    "description": {
                        "type": "string",
                        "description": "What the user needs to do to complete the quest"
                    },
                    "points": {
                        "type": "integer",
                        "description": "How many points this quest is worth (higher = harder)"
                    }
                },
                "required": ["title", "description", "points"],
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "complete_quest".to_string(),
            description: "Mark a quest as completed. Call this when the user \
                          reports finishing a quest or when you determine they \
                          have satisfied its conditions."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "The title of the quest to mark as complete"
                    }
                },
                "required": ["title"],
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "list_open_quests".to_string(),
            description: "List all currently open (incomplete) quests with their \
                          descriptions and point values."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
    ]
}

/// Execute a tool call against the game state.
///
/// Parses the call arguments, delegates to the appropriate handler, and
/// returns a human-readable outcome message.
pub fn execute(game: &mut Game, call: &ToolCall) -> ToolOutcome {
    let message = match call.name.as_str() {
        "register_quest" => execute_register_quest(game, call),
        "complete_quest" => execute_complete_quest(game, call),
        "list_open_quests" => execute_list_open_quests(game, call),
        other => format!("⚠️ Unknown tool: {other}"),
    };

    ToolOutcome {
        tool_call_id: call.id.clone(),
        message,
    }
}

// ─── Handler implementations ────────────────────────────────────────────────

fn execute_register_quest(game: &mut Game, call: &ToolCall) -> String {
    #[derive(Deserialize)]
    struct RegisterQuestArgs {
        title: String,
        description: String,
        points: u32,
    }

    let args: RegisterQuestArgs = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => {
            return format!("⚠️ Could not parse quest arguments: {e}");
        }
    };

    let quest = Quest {
        title: args.title.clone(),
        description: args.description.clone(),
        points: args.points,
    };

    match game.register_quest(quest) {
        Ok(()) => {
            format!(
                "✅ Quest registered: **{}** — {} ({} pts)",
                args.title, args.description, args.points
            )
        }
        Err(e) => format!("⚠️ {e}"),
    }
}

fn execute_complete_quest(game: &mut Game, call: &ToolCall) -> String {
    #[derive(Deserialize)]
    struct CompleteQuestArgs {
        title: String,
    }

    let args: CompleteQuestArgs = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => {
            return format!("⚠️ Could not parse quest arguments: {e}");
        }
    };

    match game.complete_quest(&args.title) {
        Ok(()) => format!("✅ Quest completed: **{}**", args.title),
        Err(e) => format!("⚠️ {e}"),
    }
}

fn execute_list_open_quests(game: &mut Game, call: &ToolCall) -> String {
    let _ = call; // no arguments to parse
    let quests = game.list_open_quests();

    if quests.is_empty() {
        return "📋 No open quests right now.".to_string();
    }

    let mut lines: Vec<String> = quests
        .iter()
        .map(|q| {
            format!("  • **{}** — {} ({} pts)", q.title, q.description, q.points)
        })
        .collect();

    let total_pts: u32 = quests.iter().map(|q| q.points).sum();
    lines.push(format!("📊 Total: {} quests, {} points available", quests.len(), total_pts));

    format!("📋 Open quests:\n{}", lines.join("\n"))
}
