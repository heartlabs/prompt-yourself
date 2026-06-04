use chrono::NaiveDate;
use uuid::Uuid;

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
        results.sort_by_key(|e| e.occurred_on);
        results
    }

    async fn remove(&mut self, id: Uuid) -> Result<(), GameError> {
        let pos = self.entries.iter().position(|e| e.id == id).ok_or_else(|| {
            GameError::Other(format!("No timeline entry with id '{}'", id))
        })?;
        self.entries.remove(pos);
        Ok(())
    }

    async fn reassign(&mut self, entry_id: Uuid, quest_id: Uuid) -> Result<(), GameError> {
        let entry = self.entries.iter_mut().find(|e| e.id == entry_id).ok_or_else(|| {
            GameError::Other(format!("No timeline entry with id '{}'", entry_id))
        })?;
        entry.quest_id = quest_id;
        Ok(())
    }
}
