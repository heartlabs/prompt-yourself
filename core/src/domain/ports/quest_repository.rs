//! Driven port for quest persistence.
//!
//! Defines the [`QuestRepository`] trait that `GameService` depends on.
//! At runtime this is implemented by an in-memory adapter
//! ([`crate::infrastructure::in_memory_quest_repo::InMemoryQuestRepository`])
//! or, on WASM, by [`WasmQuestRepository`] which persists via JS callbacks.

use chrono::{DateTime, NaiveDate, Utc};

use crate::domain::entities::game::{GameError, Quest};

/// Driven port for CRUD operations on quests.
///
/// Conditional `Send` so that WASM (`?Send`) and native targets both compile,
/// following the same pattern as [`JournalPort`](crate::domain::ports::journal::JournalPort).
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
pub trait QuestRepository: Send {
    /// Insert a new quest. The quest must have a unique title.
    async fn insert(&mut self, quest: Quest) -> Result<(), GameError>;

    /// Mark a quest as completed at the given timestamp.
    async fn mark_completed(
        &mut self,
        title: &str,
        completed_at: DateTime<Utc>,
    ) -> Result<(), GameError>;

    /// Return all quests that are not yet completed.
    async fn find_open(&self) -> Vec<Quest>;

    /// Return quests completed on the given calendar day.
    async fn find_completed_at(&self, day: NaiveDate) -> Vec<Quest>;

    /// Check whether a quest with the given title exists (completed or not).
    async fn exists(&self, title: &str) -> bool;
}
