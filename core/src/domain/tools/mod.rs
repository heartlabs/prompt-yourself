//! Tool executor for LLM function calling.
//!
//! Defines the available tools (currently quest-related) and the [`execute`]
//! function that dispatches tool calls against the domain entities.

use chrono::NaiveDate;
use serde::Deserialize;
use serde_json::json;

use crate::domain::entities::game::{GameService, Quest, QuestStatus};
use crate::domain::ports::openai::{ToolCall, ToolDefinition};

/// The outcome of executing a single tool call.
///
/// - `user_message`: concise, friendly version shown to the user
/// - `llm_message`:  detailed, structured version fed back to the LLM
pub struct ToolOutcome {
    pub tool_call_id: String,
    pub user_message: String,
    pub llm_message: String,
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
                    },
                    "pinned": {
                        "type": "boolean",
                        "description": "If true, the quest stays open after completion and can be awarded multiple times (e.g. daily check-in)"
                    }
                },
                "required": ["title", "description", "points"],
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "update_quest".to_string(),
            description: "Update an existing quest. Provide the current title to identify \
                          which quest to change, then any fields you want to modify \
                          (title, description, points, pinned). Quest status can be \
                          changed freely — set pinned=true to make it a repeatable \
                          quest, or pinned=false to make it a one-shot quest."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "currentTitle": {
                        "type": "string",
                        "description": "The current title of the quest to update"
                    },
                    "title": {
                        "type": "string",
                        "description": "New title for the quest (omit to keep current)"
                    },
                    "description": {
                        "type": "string",
                        "description": "New description (omit to keep current)"
                    },
                    "points": {
                        "type": "integer",
                        "description": "New point value (omit to keep current)"
                    },
                    "pinned": {
                        "type": "boolean",
                        "description": "Set true to make this quest pinned (repeatable), \
                                        or false to make it a regular open quest. \
                                        You can even update a completed quest \
                                        to reopen or pin it."
                    }
                },
                "required": ["currentTitle"],
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
/// `day` is the calendar day used when listing completed quests.
/// Completion timestamps use `Utc::now()` (the exact moment), not `day`.
///
/// Parses the call arguments, delegates to the appropriate handler, and
/// returns a [`ToolOutcome`] with separate messages for the user and the LLM.
pub async fn execute(
    game: &mut GameService,
    call: &ToolCall,
    day: NaiveDate,
) -> ToolOutcome {
    let (user_message, llm_message) = match call.name.as_str() {
        "register_quest" => execute_register_quest(game, call).await,
        "complete_quest" => execute_complete_quest(game, call).await,
        "update_quest" => execute_update_quest(game, call).await,
        "list_open_quests" => execute_list_open_quests(game, call, day).await,
        other => (
            format!("⚠️ Unknown tool: {other}"),
            format!("error: unknown tool '{other}'"),
        ),
    };

    ToolOutcome {
        tool_call_id: call.id.clone(),
        user_message,
        llm_message,
    }
}

// ─── Handler implementations ────────────────────────────────────────────────

async fn execute_register_quest(game: &mut GameService, call: &ToolCall) -> (String, String) {
    #[derive(Deserialize)]
    struct RegisterQuestArgs {
        title: String,
        description: String,
        points: u32,
        #[serde(default)]
        pinned: bool,
    }

    let args: RegisterQuestArgs = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => {
            return (
                format!("⚠️ Could not parse quest arguments"),
                format!("error: failed to parse register_quest arguments: {e}"),
            );
        }
    };

    let status = if args.pinned {
        QuestStatus::Pinned
    } else {
        QuestStatus::Open
    };

    let quest = Quest {
        title: args.title.clone(),
        description: args.description.clone(),
        points: args.points,
        status,
    };

    match game.register_quest(quest).await {
        Ok(()) => (
            format!("✅ Quest registered: **{}** ({} pts)", args.title, args.points),
            format!(
                "Quest '{}' registered with {} points. Description: {}",
                args.title, args.points, args.description
            ),
        ),
        Err(e) => (
            format!("⚠️ {e}"),
            format!("error: {e}"),
        ),
    }
}

async fn execute_complete_quest(
    game: &mut GameService,
    call: &ToolCall,
) -> (String, String) {
    #[derive(Deserialize)]
    struct CompleteQuestArgs {
        title: String,
    }

    let args: CompleteQuestArgs = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => {
            return (
                format!("⚠️ Could not parse quest arguments"),
                format!("error: failed to parse complete_quest arguments: {e}"),
            );
        }
    };

    match game.complete_quest(&args.title).await {
        Ok(()) => (
            format!("✅ Quest completed: **{}**", args.title),
            format!("Quest '{}' completed successfully", args.title),
        ),
        Err(e) => (
            format!("⚠️ {e}"),
            format!("error: {e}"),
        ),
    }
}

async fn execute_update_quest(
    game: &mut GameService,
    call: &ToolCall,
) -> (String, String) {
    #[derive(Deserialize)]
    struct UpdateQuestArgs {
        #[serde(rename = "currentTitle")]
        current_title: String,
        title: Option<String>,
        description: Option<String>,
        points: Option<u32>,
        pinned: Option<bool>,
    }

    let args: UpdateQuestArgs = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => {
            return (
                format!("⚠️ Could not parse quest arguments"),
                format!("error: failed to parse update_quest arguments: {e}"),
            );
        }
    };

    // Load the current quest so we can merge partial updates
    let current = match game.find_quest(&args.current_title).await {
        Ok(Some(q)) => q,
        Ok(None) => return (
            format!("⚠️ No quest found with title '{}'", args.current_title),
            format!("error: quest '{}' not found", args.current_title),
        ),
        Err(e) => return (
            format!("⚠️ {e}"),
            format!("error: {e}"),
        ),
    };

    let new_title = args.title.unwrap_or_else(|| current.title.clone());
    let new_description = args.description.unwrap_or_else(|| current.description.clone());
    let new_points = args.points.unwrap_or(current.points);
    let new_status = match args.pinned {
        Some(true) => QuestStatus::Pinned,
        Some(false) if current.status == QuestStatus::Pinned => QuestStatus::Open,
        _ => current.status, // keep current
    };

    let updated = Quest {
        title: new_title.clone(),
        description: new_description.clone(),
        points: new_points,
        status: new_status,
    };

    match game.update_quest(&args.current_title, updated).await {
        Ok(()) => {
            let mut changes = Vec::new();
            if new_title != current.title {
                changes.push(format!("title → \"{}\"", new_title));
            }
            if new_description != current.description {
                changes.push("description updated".to_string());
            }
            if new_points != current.points {
                changes.push(format!("points → {}", new_points));
            }
            if new_status != current.status {
                changes.push(format!("status → {:?}", new_status));
            }
            let desc = if changes.is_empty() {
                "No changes made.".to_string()
            } else {
                changes.join(", ")
            };
            (
                format!("✅ Quest updated: **\"{}\"** — {}", new_title, desc),
                format!("Quest '{}' updated: {}", new_title, desc),
            )
        }
        Err(e) => (
            format!("⚠️ {e}"),
            format!("error: {e}"),
        ),
    }
}

async fn execute_list_open_quests(
    game: &mut GameService,
    call: &ToolCall,
    day: NaiveDate,
) -> (String, String) {
    let _ = call; // no arguments to parse
    let open_quests = game.list_open_quests().await;
    let timeline = game.timeline_entries(day).await;

    if open_quests.is_empty() && timeline.is_empty() {
        return (
            "📋 No quests.".to_string(),
            "No quests".to_string(),
        );
    }

    let mut lines = Vec::new();

    if !open_quests.is_empty() {
        lines.push(format!("📋 {} open quest(s):", open_quests.len()));
        for q in &open_quests {
            lines.push(format!(
                "  - title: \"{}\", description: \"{}\", points: {}",
                q.title, q.description, q.points
            ));
        }
    }

    if !timeline.is_empty() {
        let pts_today: u32 = game.total_points(day).await;
        lines.push(format!(
            "✅ {} completed today ({} pts)",
            timeline.len(),
            pts_today,
        ));
        for entry in &timeline {
            if let Ok(Some(quest)) = game.find_quest(&entry.quest_title).await {
                lines.push(format!(
                    "  - title: \"{}\", points: {}",
                    quest.title, quest.points
                ));
            }
        }
    }

    let llm_msg = lines.join("\n");

    let open_count = open_quests.len();
    let completed_count = timeline.len();
    let pts_today: u32 = game.total_points(day).await;
    let user_msg = format!(
        "📋 {} open, {} completed ({} pts)",
        open_count, completed_count, pts_today,
    );

    (user_msg, llm_msg)
}
