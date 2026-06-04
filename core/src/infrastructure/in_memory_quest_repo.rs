//! In-memory quest repository backed by a `HashMap`.
//!
//! Implements [`QuestRepository`] for use when persistence is not required
//! (CLI) or not yet wired up (WASM / Obsidian).

use std::collections::HashMap;

use crate::domain::entities::game::{GameError, Quest, QuestStatus};
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

    async fn mark_completed(&mut self, title: &str) -> Result<(), GameError> {
        let quest = self.quests.get_mut(title).ok_or_else(|| {
            GameError::Other(format!("No quest found with title '{}'", title))
        })?;

        if quest.status == QuestStatus::Completed {
            return Err(GameError::Other(format!(
                "Quest '{}' is already completed",
                title
            )));
        }

        quest.status = QuestStatus::Completed;
        Ok(())
    }

    async fn find_open(&self) -> Vec<Quest> {
        self.quests
            .values()
            .filter(|q| q.status == QuestStatus::Open || q.status == QuestStatus::Pinned)
            .cloned()
            .collect()
    }

    async fn find_pinned(&self) -> Vec<Quest> {
        self.quests
            .values()
            .filter(|q| q.status == QuestStatus::Pinned)
            .cloned()
            .collect()
    }

    async fn find_by_title(&self, title: &str) -> Result<Option<Quest>, GameError> {
        Ok(self.quests.get(title).cloned())
    }

    async fn exists(&self, title: &str) -> bool {
        self.quests.contains_key(title)
    }
}
