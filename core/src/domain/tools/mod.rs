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
            description: "List all currently active quests (both Open and Pinned) \
                          along with today's timeline entries. Each quest shows its \
                          status — 'Open' means it closes on completion, 'Pinned' \
                          means it stays open and can be completed multiple times. \
                          Timeline entries include their UUID (entry ID) so you can \
                          use update_timeline on them."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "list_timeline".to_string(),
            description: "List today\'s timeline entries with full details including \
                          UUIDs, quest titles, timestamps, and point values. Use this \
                          when you need entry IDs for the update_timeline tool."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "update_timeline".to_string(),
            description: "Update a timeline entry. You can remove an entry, or \
                          reassign it to a different quest. Find the entry ID \
                          using the list_timeline tool."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["remove", "reassign"],
                        "description": "remove — delete the entry; reassign — change which quest it references"
                    },
                    "entryId": {
                        "type": "string",
                        "description": "UUID of the timeline entry to update (use list_timeline to find IDs)"
                    },
                    "newQuestTitle": {
                        "type": "string",
                        "description": "Only for reassign: the quest title to link this entry to instead"
                    }
                },
                "required": ["action", "entryId"],
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
        "update_timeline" => execute_update_timeline(game, call).await,
        "list_open_quests" => execute_list_open_quests(game, call, day).await,
        "list_timeline" => execute_list_timeline(game, call, day).await,
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

async fn execute_update_timeline(
    game: &mut GameService,
    call: &ToolCall,
) -> (String, String) {
    #[derive(Deserialize)]
    struct UpdateTimelineArgs {
        action: String,
        #[serde(rename = "entryId")]
        entry_id: String,
        #[serde(rename = "newQuestTitle")]
        new_quest_title: Option<String>,
    }

    let args: UpdateTimelineArgs = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => {
            return (
                format!("⚠️ Could not parse timeline arguments"),
                format!("error: failed to parse update_timeline arguments: {e}"),
            );
        }
    };

    let id: uuid::Uuid = match args.entry_id.parse() {
        Ok(id) => id,
        Err(e) => {
            return (
                format!("⚠️ Invalid entry ID: {e}"),
                format!("error: invalid timeline entry UUID '{}': {e}", args.entry_id),
            );
        }
    };

    match args.action.as_str() {
        "remove" => match game.remove_timeline_entry(id).await {
            Ok(()) => (
                format!("✅ Timeline entry removed"),
                format!("Timeline entry '{}' removed", args.entry_id),
            ),
            Err(e) => (
                format!("⚠️ {e}"),
                format!("error: {e}"),
            ),
        },
        "reassign" => {
            let new_title = match &args.new_quest_title {
                Some(t) => t.clone(),
                None => return (
                    format!("⚠️ newQuestTitle is required for reassign action"),
                    format!("error: newQuestTitle missing for reassign"),
                ),
            };
            match game.reassign_timeline_entry(id, &new_title).await {
                Ok(()) => (
                    format!("✅ Timeline entry reassigned to **\"{}\"**", new_title),
                    format!("Timeline entry '{}' reassigned to quest '{}'", args.entry_id, new_title),
                ),
                Err(e) => (
                    format!("⚠️ {e}"),
                    format!("error: {e}"),
                ),
            }
        }
        other => (
            format!("⚠️ Unknown action: {other}"),
            format!("error: unknown update_timeline action '{other}'"),
        ),
    }
}

async fn execute_list_timeline(
    game: &mut GameService,
    _call: &ToolCall,
    day: NaiveDate,
) -> (String, String) {
    let entries = game.timeline_entries(day).await;

    if entries.is_empty() {
        return (
            "📜 No timeline entries for today.".to_string(),
            "No timeline entries for today.".to_string(),
        );
    }

    let mut lines = vec![format!("📜 {} timeline entries:", entries.len())];

    for entry in &entries {
        if let Ok(Some(quest)) = game.find_quest(&entry.quest_title).await {
            lines.push(format!(
                "  - id: {}, quest: \"{}\", time: {}, points: {}, description: \"{}\"",
                entry.id,
                entry.quest_title,
                entry.occurred_on.format("%H:%M:%S"),
                quest.points,
                quest.description,
            ));
        } else {
            lines.push(format!(
                "  - id: {}, quest: \"{}\", time: {} (quest not found)",
                entry.id,
                entry.quest_title,
                entry.occurred_on.format("%H:%M:%S"),
            ));
        }
    }

    let llm_msg = lines.join("\n");
    let user_msg = format!("📜 {} timeline entries today", entries.len());
    (user_msg, llm_msg)
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
        lines.push(format!("📋 {} active quest(s):", open_quests.len()));
        for q in &open_quests {
            let status_label = match q.status {
                QuestStatus::Pinned => "Pinned",
                QuestStatus::Open => "Open",
                _ => "",
            };
            lines.push(format!(
                "  - title: \"{}\", description: \"{}\", points: {}, status: {}",
                q.title, q.description, q.points, status_label
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
                    "  - id: {}, title: \"{}\", points: {}",
                    entry.id, quest.title, quest.points
                ));
            }
        }
    }

    let llm_msg = lines.join("\n");

    let open_count = open_quests.len();
    let completed_count = timeline.len();
    let pts_today: u32 = game.total_points(day).await;
    let user_msg = format!(
        "📋 {} active, {} completed ({} pts)",
        open_count, completed_count, pts_today,
    );

    (user_msg, llm_msg)
}
