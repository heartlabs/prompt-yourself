use std::collections::HashMap;

use uuid::Uuid;

use crate::domain::entities::game::{GameError, Quest, QuestStatus};
use crate::domain::ports::quest_repository::QuestRepository;

/// In-memory adapter for [`QuestRepository`].
/// Primary map is `HashMap<Uuid, Quest>`. A secondary index maps title → id
/// for title uniqueness checks.
pub struct InMemoryQuestRepository {
    quests: HashMap<Uuid, Quest>,
    title_index: HashMap<String, Uuid>,
}

impl InMemoryQuestRepository {
    pub fn new() -> Self {
        Self {
            quests: HashMap::new(),
            title_index: HashMap::new(),
        }
    }
}

#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
impl QuestRepository for InMemoryQuestRepository {
    async fn insert(&mut self, quest: Quest) -> Result<(), GameError> {
        if self.title_index.contains_key(&quest.title) {
            return Err(GameError::Other(format!(
                "Quest with title '{}' already exists",
                quest.title
            )));
        }
        let id = quest.id;
        self.title_index.insert(quest.title.clone(), id);
        self.quests.insert(id, quest);
        Ok(())
    }

    async fn mark_completed(&mut self, id: Uuid) -> Result<(), GameError> {
        let quest = self.quests.get_mut(&id).ok_or_else(|| {
            GameError::Other(format!("No quest found with id '{}'", id))
        })?;

        if quest.status == QuestStatus::Completed {
            return Err(GameError::Other(format!(
                "Quest '{}' is already completed",
                quest.title
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

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Quest>, GameError> {
        Ok(self.quests.get(&id).cloned())
    }

    async fn title_exists(&self, title: &str) -> bool {
        self.title_index.contains_key(title)
    }

    async fn update(&mut self, id: Uuid, quest: Quest) -> Result<(), GameError> {
        if !self.quests.contains_key(&id) {
            return Err(GameError::Other(format!(
                "No quest found with id '{}'",
                id
            )));
        }

        // If the title is changing, make sure the new title doesn't clash
        let current = &self.quests[&id];
        if current.title != quest.title && self.title_index.contains_key(&quest.title) {
            return Err(GameError::Other(format!(
                "A quest with title '{}' already exists",
                quest.title
            )));
        }

        // Update the title index
        self.title_index.remove(&current.title);
        self.title_index.insert(quest.title.clone(), id);

        self.quests.insert(id, quest);
        Ok(())
    }
}
