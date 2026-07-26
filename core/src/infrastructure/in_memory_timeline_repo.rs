use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::entities::game::{EnergyLevel, GameError, TimelineEntry, TimelineEntryData};
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
        match &mut entry.data {
            TimelineEntryData::QuestCompletion { quest_id: ref mut qid } => {
                *qid = quest_id;
                Ok(())
            }
            _ => Err(GameError::Other("Cannot reassign a non-quest timeline entry".into())),
        }
    }

    async fn update_energy_level(&mut self, entry_id: Uuid, level: EnergyLevel) -> Result<(), GameError> {
        let entry = self.entries.iter_mut().find(|e| e.id == entry_id).ok_or_else(|| {
            GameError::Other(format!("No timeline entry with id '{}'", entry_id))
        })?;
        match &mut entry.data {
            TimelineEntryData::CheckIn { energy_level, .. } => {
                *energy_level = level;
                Ok(())
            }
            _ => Err(GameError::Other("Cannot change energy on a non-check-in entry".into())),
        }
    }
}
