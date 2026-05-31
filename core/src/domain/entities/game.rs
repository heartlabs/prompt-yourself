/// The "game" consists of "quests" that the Chat Coach can assign to the user. 
/// It's also the chat coach's job to decide when a quest is complete and to keep track which quests are available.
/// On API level the user will be informed about new quests and quest completions via the chat messages. 
/// Additionally there will be a dedicated API to show open and completed quests and collected points.

use chrono::{DateTime, NaiveDate, Utc};

use crate::domain::ports::quest_repository::QuestRepository;

/// Service that manages quests through a [`QuestRepository`] port.
///
/// All quest state is delegated to the repository, making the service
/// independent of the storage mechanism.
pub struct GameService {
    repo: Box<dyn QuestRepository>,
}

impl GameService {
    /// Create a new game service backed by the given repository.
    pub fn new(repo: Box<dyn QuestRepository>) -> Self {
        Self { repo }
    }

    pub async fn register_quest(
        &mut self,
        quest: Quest
    ) -> Result<(), GameError> {
        self.repo.insert(quest).await
    }

    pub async fn complete_quest(
        &mut self,
        title: &str,
        completed_at: DateTime<Utc>,
    ) -> Result<(), GameError> {
        self.repo.mark_completed(title, completed_at).await
    }

    pub async fn list_open_quests(&self) -> Vec<Quest> {
        self.repo.find_open().await
    }

    /// Return quests completed on the given calendar day.
    pub async fn list_completed_quests(&self, day: NaiveDate) -> Vec<Quest> {
        self.repo.find_completed_at(day).await
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
    /// `None` while the quest is still open; `Some(timestamp)` when completed.
    pub completed_at: Option<DateTime<Utc>>,
}
