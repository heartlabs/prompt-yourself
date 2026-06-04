//! Driven port for quest persistence.
//!
//! Defines the [`QuestRepository`] trait that `GameService` depends on.
//! At runtime this is implemented by an in-memory adapter
//! ([`crate::infrastructure::in_memory_quest_repo::InMemoryQuestRepository`])
//! or, on WASM, by [`WasmQuestRepository`] which persists via JS callbacks.

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

    /// Mark an open quest as completed (sets status to `Completed`).
    async fn mark_completed(&mut self, title: &str) -> Result<(), GameError>;

    /// Return all quests that are still open (status is `Open` or `Pinned`).
    async fn find_open(&self) -> Vec<Quest>;

    /// Return all quests with status `Pinned`.
    async fn find_pinned(&self) -> Vec<Quest>;

    /// Look up a single quest by title.
    async fn find_by_title(&self, title: &str) -> Result<Option<Quest>, GameError>;

    /// Check whether a quest with the given title exists.
    async fn exists(&self, title: &str) -> bool;

    /// Update a quest identified by its current title.  Replaces every field
    /// (title, description, points, status) so the caller must provide a full
    /// [`Quest`] value.  The `current_title` is used to look up the existing
    /// quest before the rename is applied.
    async fn update(&mut self, current_title: &str, quest: Quest) -> Result<(), GameError>;
}
