use uuid::Uuid;

use crate::domain::entities::game::{GameError, Quest};

/// Driven port for CRUD operations on quests.
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
pub trait QuestRepository: Send {
    /// Insert a new quest. The quest must already have an id set.
    /// Title uniqueness is enforced.
    async fn insert(&mut self, quest: Quest) -> Result<(), GameError>;

    /// Mark a quest as completed (sets status to `Completed`).
    async fn mark_completed(&mut self, id: Uuid) -> Result<(), GameError>;

    /// Return all quests with status `Open` or `Pinned`.
    async fn find_open(&self) -> Vec<Quest>;

    /// Return all quests with status `Pinned`.
    async fn find_pinned(&self) -> Vec<Quest>;

    /// Look up a single quest by UUID.
    async fn find_by_id(&self, id: Uuid) -> Result<Option<Quest>, GameError>;

    /// Check whether a quest with the given title exists.
    async fn title_exists(&self, title: &str) -> bool;

    /// Update a quest identified by UUID. Replaces every field
    /// (title, description, points, status) so the caller must provide a full
    /// [`Quest`] value.
    async fn update(&mut self, id: Uuid, quest: Quest) -> Result<(), GameError>;
}
