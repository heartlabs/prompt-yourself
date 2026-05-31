//! In-memory quest repository backed by a `HashMap`.
//!
//! Implements [`QuestRepository`] for use when persistence is not required
//! (CLI) or not yet wired up (WASM / Obsidian).  The map is keyed by quest
//! title.  Each [`Quest`] carries its own `completed` flag, so there is no
//! separate collection for completed quests — they are simply filtered at
//! query time.

use std::collections::HashMap;

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

impl QuestRepository for InMemoryQuestRepository {
    fn insert(&mut self, quest: Quest) -> Result<(), GameError> {
        if self.quests.contains_key(&quest.title) {
            return Err(GameError::Other(format!(
                "Quest with title '{}' already exists",
                quest.title
            )));
        }
        self.quests.insert(quest.title.clone(), quest);
        Ok(())
    }

    fn mark_completed(&mut self, title: &str) -> Result<(), GameError> {
        let quest = self.quests.get_mut(title).ok_or_else(|| {
            GameError::Other(format!("No quest found with title '{}'", title))
        })?;

        if quest.completed {
            return Err(GameError::Other(format!(
                "Quest '{}' is already completed",
                title
            )));
        }

        quest.completed = true;
        Ok(())
    }

    fn find_open(&self) -> Vec<Quest> {
        self.quests
            .values()
            .filter(|q| !q.completed)
            .cloned()
            .collect()
    }

    fn find_completed(&self) -> Vec<Quest> {
        self.quests
            .values()
            .filter(|q| q.completed)
            .cloned()
            .collect()
    }

    fn exists(&self, title: &str) -> bool {
        self.quests.contains_key(title)
    }
}
