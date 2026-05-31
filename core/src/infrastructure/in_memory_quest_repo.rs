//! In-memory quest repository backed by a `HashMap`.
//!
//! Implements [`QuestRepository`] for use when persistence is not required
//! (CLI) or not yet wired up (WASM / Obsidian).  The map is keyed by quest
//! title.  Each [`Quest`] carries its own `completed_at` timestamp — open
//! quests have `completed_at: None`.

use std::collections::HashMap;

use chrono::{DateTime, NaiveDate, Utc};

use crate::domain::entities::game::{GameError, Quest};
use crate::domain::ports::quest_repository::QuestRepository;

/// In-memory adapter for [`QuestRepository`].
pub struct InMemoryQuestRepository {
    quests: HashMap<String, Quest>,
}

impl InMemoryQuestRepository {
    pub fn new() -> Self {
        Self {
            quests: HashMap::new(),
        }
    }
}

#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
impl QuestRepository for InMemoryQuestRepository {
    async fn insert(&mut self, quest: Quest) -> Result<(), GameError> {
        if self.quests.contains_key(&quest.title) {
            return Err(GameError::Other(format!(
                "Quest with title '{}' already exists",
                quest.title
            )));
        }
        self.quests.insert(quest.title.clone(), quest);
        Ok(())
    }

    async fn mark_completed(
        &mut self,
        title: &str,
        completed_at: DateTime<Utc>,
    ) -> Result<(), GameError> {
        let quest = self.quests.get_mut(title).ok_or_else(|| {
            GameError::Other(format!("No quest found with title '{}'", title))
        })?;

        if quest.completed_at.is_some() {
            return Err(GameError::Other(format!(
                "Quest '{}' is already completed",
                title
            )));
        }

        quest.completed_at = Some(completed_at);
        Ok(())
    }

    async fn find_open(&self) -> Vec<Quest> {
        self.quests
            .values()
            .filter(|q| q.completed_at.is_none())
            .cloned()
            .collect()
    }

    async fn find_completed_at(&self, day: NaiveDate) -> Vec<Quest> {
        self.quests
            .values()
            .filter(|q| q.completed_at.is_some_and(|ts| ts.date_naive() == day))
            .cloned()
            .collect()
    }

    async fn exists(&self, title: &str) -> bool {
        self.quests.contains_key(title)
    }
}
