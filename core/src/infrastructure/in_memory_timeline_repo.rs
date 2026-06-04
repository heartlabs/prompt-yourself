//! In-memory timeline repository backed by a `Vec`.
//!
//! Implements [`TimelineRepository`] for use when persistence is not required
//! (CLI) or not yet wired up (WASM / Obsidian).

use chrono::NaiveDate;

use crate::domain::entities::game::{GameError, TimelineEntry};
use crate::domain::ports::timeline_repository::TimelineRepository;

/// In-memory adapter for [`TimelineRepository`].
pub struct InMemoryTimelineRepository {
    entries: Vec<TimelineEntry>,
}

impl InMemoryTimelineRepository {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }
}

#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
impl TimelineRepository for InMemoryTimelineRepository {
    async fn record(&mut self, entry: TimelineEntry) -> Result<(), GameError> {
        self.entries.push(entry);
        Ok(())
    }

    async fn find_by_date(&self, day: NaiveDate) -> Vec<TimelineEntry> {
        let mut results: Vec<TimelineEntry> = self
            .entries
            .iter()
            .filter(|e| e.occurred_on.date_naive() == day)
            .cloned()
            .collect();
        // Chronological order (oldest first)
        results.sort_by_key(|e| e.occurred_on);
        results
    }
}
