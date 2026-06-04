//! Driven port for timeline entry persistence.
//!
//! Each time a quest is completed (one-shot or pinned), a [`TimelineEntry`]
//! is recorded here. The timeline is the source of truth for "what happened
//! today" — it does not own point values (those live on the referenced quest).

use chrono::NaiveDate;

use crate::domain::entities::game::{GameError, TimelineEntry};

/// Driven port for CRUD operations on timeline entries.
///
/// Conditional `Send` so that WASM (`?Send`) and native targets both compile.
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
pub trait TimelineRepository: Send {
    /// Record a new timeline entry.
    async fn record(&mut self, entry: TimelineEntry) -> Result<(), GameError>;

    /// All timeline entries for the given calendar day.
    async fn find_by_date(&self, day: NaiveDate) -> Vec<TimelineEntry>;
}
