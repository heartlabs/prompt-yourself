/// The "game" consists of "quests" that the Chat Coach can assign to the user. 
/// It's also the chat coach's job to decide when a quest is complete and to keep track which quests are available.
/// On API level the user will be informed about new quests and quest completions via the chat messages. 
/// Additionally there will be a dedicated API to show open and completed quests and collected points.

pub struct Game {
    open_quests: Vec<Quest>,
    completed_quests: Vec<Quest>,
}

impl Game {
    pub fn new() -> Self {
        Self {
            open_quests: Vec::new(),
            completed_quests: Vec::new(),
        }
    }

    pub fn register_quest(
        &mut self,
        quest: Quest
    ) -> Result<(), GameError> {
        // Check if quest with the same title already exists
        if self.open_quests.iter().any(|q| q.title == quest.title)
            || self.completed_quests.iter().any(|q| q.title == quest.title)
        {
            return Err(GameError::Other(format!(
                "Quest with title '{}' already exists",
                quest.title
            )));
        }

        // Add the new quest to the list of open quests
        self.open_quests.push(quest);
        Ok(())
    }

    pub fn complete_quest(&mut self, title: &str) -> Result<(), GameError> {
        // Find the quest in the list of open quests
        if let Some(pos) = self.open_quests.iter().position(|q| q.title == title) {
            let quest = self.open_quests.remove(pos);
            self.completed_quests.push(quest);
            Ok(())
        } else {
            Err(GameError::Other(format!(
                "No open quest found with title '{}'",
                title
            )))
        }
    }

    pub fn list_open_quests(&self) -> Vec<Quest> {
        let mut open_quests = Vec::new();
        open_quests.extend(self.open_quests.iter().cloned());
        open_quests
    }

    pub fn list_completed_quests(&self) -> Vec<Quest> {
        let mut completed_quests = Vec::new();
        completed_quests.extend(self.completed_quests.iter().cloned());
        completed_quests
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
}