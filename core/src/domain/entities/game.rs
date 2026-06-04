use chrono::{DateTime, NaiveDate, Utc};
use uuid::Uuid;

use crate::domain::ports::quest_repository::QuestRepository;
use crate::domain::ports::timeline_repository::TimelineRepository;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum QuestStatus {
    Open,
    Completed,
    Pinned,
}

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

    /// Insert a new quest. If no id is set, a new UUID is generated.
    pub async fn register_quest(&mut self, mut quest: Quest) -> Result<(), GameError> {
        quest.id = Uuid::new_v4();
        self.quest_repo.insert(quest).await
    }

    /// Complete a quest identified by UUID.
    pub async fn complete_quest(&mut self, quest_id: Uuid) -> Result<(), GameError> {
        let quest = self.quest_repo.find_by_id(quest_id).await?
            .ok_or_else(|| GameError::Other(format!(
                "No quest found with id '{}'", quest_id
            )))?;

        match quest.status {
            QuestStatus::Completed => {
                return Err(GameError::Other(format!(
                    "Quest '{}' is already completed",
                    quest.title
                )));
            }
            QuestStatus::Pinned => {
                // stays pinned — just record the timeline entry
            }
            QuestStatus::Open => {
                self.quest_repo.mark_completed(quest_id).await?;
            }
        }

        let entry = TimelineEntry {
            id: Uuid::new_v4(),
            quest_id,
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

    pub async fn timeline_entries(&self, day: NaiveDate) -> Vec<TimelineEntry> {
        self.timeline_repo.find_by_date(day).await
    }

    pub async fn total_points(&self, day: NaiveDate) -> u32 {
        let entries = self.timeline_repo.find_by_date(day).await;
        let mut total = 0u32;
        for entry in &entries {
            if let Ok(Some(quest)) = self.quest_repo.find_by_id(entry.quest_id).await {
                total += quest.points;
            }
        }
        total
    }

    pub async fn update_quest(&mut self, quest_id: Uuid, quest: Quest) -> Result<(), GameError> {
        self.quest_repo.update(quest_id, quest).await
    }

    pub async fn remove_timeline_entry(&mut self, id: Uuid) -> Result<(), GameError> {
        self.timeline_repo.remove(id).await
    }

    pub async fn reassign_timeline_entry(&mut self, entry_id: Uuid, quest_id: Uuid) -> Result<(), GameError> {
        self.timeline_repo.reassign(entry_id, quest_id).await
    }

    pub async fn find_quest_by_id(&self, id: Uuid) -> Result<Option<Quest>, GameError> {
        self.quest_repo.find_by_id(id).await
    }
}

#[derive(Debug, thiserror::Error)]
pub enum GameError {
    #[error("{0}")]
    Other(String),
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Quest {
    pub id: Uuid,
    pub title: String,
    pub description: String,
    pub points: u32,
    pub status: QuestStatus,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TimelineEntry {
    pub id: Uuid,
    pub quest_id: Uuid,
    pub occurred_on: DateTime<Utc>,
}
