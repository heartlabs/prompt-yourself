/// The "game" consists of "quests" that the Chat Coach can assign to the user. 
/// It's also the chat coach's job to decide when a quest is complete and to keep track which quests are available.
/// On API level the user will be informed about new quests and quest completions via the chat messages. 
/// Additionally there will be a dedicated API to show open and completed quests and collected points.

use crate::domain::ports::quest_repository::QuestRepository;

/// Service that manages quests through a [`QuestRepository`] port.
///
/// All quest state is delegated to the repository, making the service
/// independent of the storage mechanism.  The in-memory implementation
/// ([`crate::infrastructure::in_memory_quest_repo::InMemoryQuestRepository`])
/// is the default; a vault-backed adapter is planned for Obsidian.
pub struct GameService {
    repo: Box<dyn QuestRepository>,
}

impl GameService {
    /// Create a new game service backed by the given repository.
    pub fn new(repo: Box<dyn QuestRepository>) -> Self {
        Self { repo }
    }

    pub fn register_quest(
        &mut self,
        quest: Quest
    ) -> Result<(), GameError> {
        self.repo.insert(quest)
    }

    pub fn complete_quest(&mut self, title: &str) -> Result<(), GameError> {
        self.repo.mark_completed(title)
    }

    pub fn list_open_quests(&self) -> Vec<Quest> {
        self.repo.find_open()
    }

    pub fn list_completed_quests(&self) -> Vec<Quest> {
        self.repo.find_completed()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum GameError {
    #[error("{0}")]
    Other(String),
}

#[derive(Debug, Clone)]
pub struct Quest {
    pub title: String,
    pub description: String,
    pub points: u32,
    /// Whether the quest has been marked as completed by the chat coach.
    pub completed: bool,
}
