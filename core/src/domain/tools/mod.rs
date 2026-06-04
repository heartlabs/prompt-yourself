use chrono::NaiveDate;
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

use crate::domain::entities::game::{GameService, Quest, QuestStatus};
use crate::domain::ports::openai::{ToolCall, ToolDefinition};

pub struct ToolOutcome {
    pub tool_call_id: String,
    pub user_message: String,
    pub llm_message: String,
}

pub fn tool_definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: "register_quest".to_string(),
            description: "Register a new quest for the user to work toward."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "A short, catchy title" },
                    "description": { "type": "string", "description": "What the user needs to do" },
                    "points": { "type": "integer", "description": "Point value (higher = harder)" },
                    "pinned": { "type": "boolean", "description": "If true, stays open after completion and can be awarded multiple times" }
                },
                "required": ["title", "description", "points"],
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "complete_quest".to_string(),
            description: "Mark a quest as completed. Use the quest ID (shown in quest listings)."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "questId": { "type": "string", "description": "UUID of the quest to complete" }
                },
                "required": ["questId"],
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "update_quest".to_string(),
            description: "Update an existing quest. Provide the quest ID (from quest listings) \
                          and any fields you want to change. Title, description, points, \
                          and pinned status can all be modified — even on completed quests."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "questId": { "type": "string", "description": "UUID of the quest to update" },
                    "title": { "type": "string", "description": "New title (omit to keep current)" },
                    "description": { "type": "string", "description": "New description (omit to keep current)" },
                    "points": { "type": "integer", "description": "New point value (omit to keep current)" },
                    "pinned": { "type": "boolean", "description": "true = pin, false = unpin. Works on completed quests too." }
                },
                "required": ["questId"],
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "list_open_quests".to_string(),
            description: "List all active quests (both Open and Pinned) with their \
                          UUIDs, descriptions, and point values. Also shows today's \
                          timeline entries with their entry IDs."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "list_timeline".to_string(),
            description: "List today's timeline entries with full details including \
                          UUIDs, quest IDs, timestamps, and point values. Use this \
                          to find entry IDs for the update_timeline tool."
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "update_timeline".to_string(),
            description: "Update a timeline entry. Remove an entry, or reassign it \
                          to a different quest using the quest's UUID."
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
                        "description": "UUID of the timeline entry to update (use list_timeline to find)"
                    },
                    "newQuestId": {
                        "type": "string",
                        "description": "Only for reassign: UUID of the quest to link this entry to"
                    }
                },
                "required": ["action", "entryId"],
                "additionalProperties": false
            }),
        },
    ]
}

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

// ─── Handlers ───────────────────────────────────────────────────────────────

async fn execute_register_quest(game: &mut GameService, call: &ToolCall) -> (String, String) {
    #[derive(Deserialize)]
    struct Args { title: String, description: String, points: u32, #[serde(default)] pinned: bool }

    let args: Args = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => return (
            "⚠️ Could not parse quest arguments".into(),
            format!("error: failed to parse register_quest arguments: {e}"),
        ),
    };

    let status = if args.pinned { QuestStatus::Pinned } else { QuestStatus::Open };

    let quest = Quest {
        id: Uuid::nil(), // GameService.register_quest generates the real UUID
        title: args.title.clone(),
        description: args.description.clone(),
        points: args.points,
        status,
    };

    match game.register_quest(quest).await {
        Ok(()) => (
            format!("✅ Quest registered: **{}** ({} pts)", args.title, args.points),
            format!("Quest '{}' registered with {} points. Description: {}", args.title, args.points, args.description),
        ),
        Err(e) => (format!("⚠️ {e}"), format!("error: {e}")),
    }
}

async fn execute_complete_quest(game: &mut GameService, call: &ToolCall) -> (String, String) {
    #[derive(Deserialize)]
    struct Args { #[serde(rename = "questId")] quest_id: String }

    let args: Args = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => return (
            "⚠️ Could not parse quest arguments".into(),
            format!("error: failed to parse complete_quest arguments: {e}"),
        ),
    };

    let id: Uuid = match args.quest_id.parse() {
        Ok(id) => id,
        Err(e) => return (
            format!("⚠️ Invalid quest ID: {e}"),
            format!("error: invalid quest UUID '{}': {e}", args.quest_id),
        ),
    };

    match game.complete_quest(id).await {
        Ok(()) => (
            "✅ Quest completed".into(),
            format!("Quest '{}' completed successfully", id),
        ),
        Err(e) => (format!("⚠️ {e}"), format!("error: {e}")),
    }
}

async fn execute_update_quest(game: &mut GameService, call: &ToolCall) -> (String, String) {
    #[derive(Deserialize)]
    struct Args {
        #[serde(rename = "questId")] quest_id: String,
        title: Option<String>,
        description: Option<String>,
        points: Option<u32>,
        pinned: Option<bool>,
    }

    let args: Args = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => return (
            "⚠️ Could not parse quest arguments".into(),
            format!("error: failed to parse update_quest arguments: {e}"),
        ),
    };

    let id: Uuid = match args.quest_id.parse() {
        Ok(id) => id,
        Err(e) => return (
            format!("⚠️ Invalid quest ID: {e}"),
            format!("error: invalid quest UUID '{}': {e}", args.quest_id),
        ),
    };

    let current = match game.find_quest_by_id(id).await {
        Ok(Some(q)) => q,
        Ok(None) => return (
            format!("⚠️ No quest found with id '{}'", args.quest_id),
            format!("error: quest '{}' not found", args.quest_id),
        ),
        Err(e) => return (format!("⚠️ {e}"), format!("error: {e}")),
    };

    let new_title = args.title.unwrap_or_else(|| current.title.clone());
    let new_description = args.description.unwrap_or_else(|| current.description.clone());
    let new_points = args.points.unwrap_or(current.points);
    let new_status = match args.pinned {
        Some(true) => QuestStatus::Pinned,
        Some(false) if current.status == QuestStatus::Pinned => QuestStatus::Open,
        _ => current.status,
    };

    let updated = Quest {
        id,
        title: new_title.clone(),
        description: new_description.clone(),
        points: new_points,
        status: new_status,
    };

    match game.update_quest(id, updated).await {
        Ok(()) => {
            let mut changes = Vec::new();
            if new_title != current.title { changes.push(format!("title → \"{}\"", new_title)); }
            if new_description != current.description { changes.push("description updated".into()); }
            if new_points != current.points { changes.push(format!("points → {}", new_points)); }
            if new_status != current.status { changes.push(format!("status → {:?}", new_status)); }
            let desc = if changes.is_empty() { "No changes made.".into() } else { changes.join(", ") };
            (format!("✅ Quest updated: **\"{}\"** — {}", new_title, desc), format!("Quest '{}' updated: {}", new_title, desc))
        }
        Err(e) => (format!("⚠️ {e}"), format!("error: {e}")),
    }
}

async fn execute_update_timeline(game: &mut GameService, call: &ToolCall) -> (String, String) {
    #[derive(Deserialize)]
    struct Args {
        action: String,
        #[serde(rename = "entryId")] entry_id: String,
        #[serde(rename = "newQuestId")] new_quest_id: Option<String>,
    }

    let args: Args = match serde_json::from_str(&call.arguments) {
        Ok(a) => a,
        Err(e) => return (
            "⚠️ Could not parse timeline arguments".into(),
            format!("error: failed to parse update_timeline arguments: {e}"),
        ),
    };

    let entry_id: Uuid = match args.entry_id.parse() {
        Ok(id) => id,
        Err(e) => return (
            format!("⚠️ Invalid entry ID: {e}"),
            format!("error: invalid timeline entry UUID '{}': {e}", args.entry_id),
        ),
    };

    match args.action.as_str() {
        "remove" => match game.remove_timeline_entry(entry_id).await {
            Ok(()) => ("✅ Timeline entry removed".into(), format!("Timeline entry '{}' removed", args.entry_id)),
            Err(e) => (format!("⚠️ {e}"), format!("error: {e}")),
        },
        "reassign" => {
            let new_quest_id: Uuid = match &args.new_quest_id {
                Some(s) => match s.parse() {
                    Ok(id) => id,
                    Err(e) => return (
                        format!("⚠️ Invalid quest ID: {e}"),
                        format!("error: invalid quest UUID '{}': {e}", s),
                    ),
                },
                None => return (
                    "⚠️ newQuestId is required for reassign action".into(),
                    "error: newQuestId missing for reassign".into(),
                ),
            };
            match game.reassign_timeline_entry(entry_id, new_quest_id).await {
                Ok(()) => (
                    format!("✅ Timeline entry reassigned to quest '{}'", new_quest_id),
                    format!("Timeline entry '{}' reassigned to quest '{}'", args.entry_id, new_quest_id),
                ),
                Err(e) => (format!("⚠️ {e}"), format!("error: {e}")),
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
        return ("📜 No timeline entries for today.".into(), "No timeline entries for today.".into());
    }

    let mut lines = vec![format!("📜 {} timeline entries:", entries.len())];

    for entry in &entries {
        if let Ok(Some(quest)) = game.find_quest_by_id(entry.quest_id).await {
            lines.push(format!(
                "  - id: {}, quest: \"{}\" (id: {}), time: {}, points: {}, description: \"{}\"",
                entry.id, quest.title, quest.id, entry.occurred_on.format("%H:%M:%S"), quest.points, quest.description,
            ));
        } else {
            lines.push(format!(
                "  - id: {}, quest_id: {}, time: {} (quest not found)",
                entry.id, entry.quest_id, entry.occurred_on.format("%H:%M:%S"),
            ));
        }
    }

    let llm_msg = lines.join("\n");
    (format!("📜 {} timeline entries today", entries.len()), llm_msg)
}

async fn execute_list_open_quests(
    game: &mut GameService,
    _call: &ToolCall,
    day: NaiveDate,
) -> (String, String) {
    let open_quests = game.list_open_quests().await;
    let timeline = game.timeline_entries(day).await;

    if open_quests.is_empty() && timeline.is_empty() {
        return ("📋 No quests.".into(), "No quests".into());
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
                "  - id: {}, title: \"{}\", description: \"{}\", points: {}, status: {}",
                q.id, q.title, q.description, q.points, status_label,
            ));
        }
    }

    if !timeline.is_empty() {
        let pts_today: u32 = game.total_points(day).await;
        lines.push(format!("✅ {} completed today ({} pts)", timeline.len(), pts_today));
        for entry in &timeline {
            if let Ok(Some(quest)) = game.find_quest_by_id(entry.quest_id).await {
                lines.push(format!(
                    "  - id: {}, title: \"{}\", points: {}",
                    entry.id, quest.title, quest.points,
                ));
            }
        }
    }

    let llm_msg = lines.join("\n");
    let open_count = open_quests.len();
    let completed_count = timeline.len();
    let pts_today: u32 = game.total_points(day).await;
    let user_msg = format!("📋 {} active, {} completed ({} pts)", open_count, completed_count, pts_today);

    (user_msg, llm_msg)
}
