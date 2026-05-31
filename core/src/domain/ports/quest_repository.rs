//! Driven port for quest persistence.
//!
//! Defines the [`QuestRepository`] trait that `GameService` depends on.
//! At runtime this is implemented by an in-memory adapter
//! ([`crate::infrastructure::in_memory_quest_repo::InMemoryQuestRepository`]);
//! a vault-backed adapter is planned for future Obsidian persistence.

use crate::domain::entities::game::{GameError, Quest};

/// Driven port for CRUD operations on quests.
pub trait QuestRepository: Send {
    /// Insert a new quest. The quest must have a unique title.
    fn insert(&mut self, quest: Quest) -> Result<(), GameError>;

    /// Mark a quest as completed by its title.
    fn mark_completed(&mut self, title: &str) -> Result<(), GameError>;

    /// Return all quests that are not yet completed.
    fn find_open(&self) -> Vec<Quest>;

    /// Return all completed quests.
    fn find_completed(&self) -> Vec<Quest>;

    /// Check whether a quest with the given title exists (completed or not).
    fn exists(&self, title: &str) -> bool;
}
