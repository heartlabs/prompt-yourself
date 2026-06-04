/// The "game" consists of "quests" that the Chat Coach can assign to the user. 
/// It's also the chat coach's job to decide when a quest is complete and to keep track which quests are available.
/// On API level the user will be informed about new quests and quest completions via the chat messages. 
/// Additionally there will be a dedicated API to show open and completed quests and collected points.

use chrono::{DateTime, NaiveDate, Utc};

use crate::domain::ports::quest_repository::QuestRepository;
use crate::domain::ports::timeline_repository::TimelineRepository;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum QuestStatus {
    Open,
    Completed,
    Pinned,
}

/// Service that manages quests through a [`QuestRepository`] port
/// and records completions in a [`TimelineRepository`] port.
pub struct GameService {
    quest_repo: Box<dyn QuestRepository>,
    timeline_repo: Box<dyn TimelineRepository>,
}

impl GameService {
    pub fn new(
        quest_repo: Box<dyn QuestRepository>,
        timeline_repo: Box<dyn TimelineRepository>,
    ) -> Self {
        Self { quest_repo, timeline_repo }
    }

    pub async fn register_quest(&mut self, quest: Quest) -> Result<(), GameError> {
        self.quest_repo.insert(quest).await
    }

    /// Complete a quest. For one-shot quests the status becomes `Completed`;
    /// for pinned quests the status stays `Pinned`. Either way, a
    /// [`TimelineEntry`] is recorded.
    pub async fn complete_quest(&mut self, title: &str) -> Result<(), GameError> {
        let quest = self.quest_repo.find_by_title(title).await?
            .ok_or_else(|| GameError::Other(format!(
                "No quest found with title '{}'", title
            )))?;

        match quest.status {
            QuestStatus::Completed => {
                return Err(GameError::Other(format!(
                    "Quest '{}' is already completed",
                    title
                )));
            }
            QuestStatus::Pinned => {
                // stays pinned — just record the timeline entry
            }
            QuestStatus::Open => {
                self.quest_repo.mark_completed(title).await?;
            }
        }

        let entry = TimelineEntry {
            quest_title: title.to_string(),
            occurred_on: Utc::now(),
        };
        self.timeline_repo.record(entry).await
    }

    pub async fn list_open_quests(&self) -> Vec<Quest> {
        self.quest_repo.find_open().await
    }

    pub async fn list_pinned_quests(&self) -> Vec<Quest> {
        self.quest_repo.find_pinned().await
    }

    /// Return timeline entries for the given calendar day.
    pub async fn timeline_entries(&self, day: NaiveDate) -> Vec<TimelineEntry> {
        self.timeline_repo.find_by_date(day).await
    }

    /// Return total points earned on the given calendar day by looking up
    /// each timeline entry's quest points.
    pub async fn total_points(&self, day: NaiveDate) -> u32 {
        let entries = self.timeline_repo.find_by_date(day).await;
        let mut total = 0u32;
        for entry in &entries {
            if let Ok(Some(quest)) = self.quest_repo.find_by_title(&entry.quest_title).await {
                total += quest.points;
            }
        }
        total
    }

    /// Look up a quest by title for tool handlers.
    pub async fn find_quest(&self, title: &str) -> Result<Option<Quest>, GameError> {
        self.quest_repo.find_by_title(title).await
    }
}

#[derive(Debug, thiserror::Error)]
pub enum GameError {
    #[error("{0}")]
    Other(String),
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Quest {
    pub title: String,
    pub description: String,
    pub points: u32,
    pub status: QuestStatus,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TimelineEntry {
    pub quest_title: String,
    pub occurred_on: DateTime<Utc>,
}
