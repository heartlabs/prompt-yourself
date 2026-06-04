//! WASM timeline repository adapter that persists timeline entries via JS callbacks.

use std::cell::RefCell;

#[cfg_attr(not(target_arch = "wasm32"), allow(unused_imports))]
use chrono::NaiveDate;
use prompt_yourself_core::domain::entities::game::{GameError, TimelineEntry};
use prompt_yourself_core::domain::ports::timeline_repository::TimelineRepository;
#[cfg(target_arch = "wasm32")]
use serde_json::json;
use uuid::Uuid;
use wasm_bindgen::prelude::*;

use crate::reentry_guard::ReentryGuard;

// ─── Callbacks & state ──────────────────────────────────────────────────────

#[allow(dead_code)]
struct TimelineCallbacks {
    save_timeline: js_sys::Function,
    load_timeline: js_sys::Function,
}

pub(crate) mod timeline_internals {
    use super::*;
    thread_local! {
        pub static TIMELINE_CALLBACKS: RefCell<Option<TimelineCallbacks>> = const { RefCell::new(None) };
        pub static TIMELINE_CACHE: RefCell<Vec<TimelineEntry>> = const { RefCell::new(Vec::new()) };
        pub static TIMELINE_CACHE_LOADED: RefCell<bool> = const { RefCell::new(false) };
    }
}

use timeline_internals::*;

// ─── WASM export ────────────────────────────────────────────────────────────

#[wasm_bindgen(js_name = setTimelineRepositoryCallbacks)]
pub fn wasm_set_timeline_repository_callbacks(callbacks: &js_sys::Object) -> Result<(), JsError> {
    let load_timeline = js_sys::Reflect::get(callbacks, &JsValue::from("loadTimeline"))
        .map_err(|_| JsError::new("loadTimeline callback missing"))?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| JsError::new("loadTimeline must be a function"))?;
    let save_timeline = js_sys::Reflect::get(callbacks, &JsValue::from("saveTimeline"))
        .map_err(|_| JsError::new("saveTimeline callback missing"))?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| JsError::new("saveTimeline must be a function"))?;
    TIMELINE_CALLBACKS.with(|cb| { *cb.borrow_mut() = Some(TimelineCallbacks { load_timeline, save_timeline }); });
    TIMELINE_CACHE_LOADED.with(|loaded| *loaded.borrow_mut() = false);
    Ok(())
}

// ─── Adapter ────────────────────────────────────────────────────────────────

pub struct WasmTimelineRepository;

#[cfg(target_arch = "wasm32")]
#[async_trait::async_trait(?Send)]
impl TimelineRepository for WasmTimelineRepository {
    async fn record(&mut self, entry: TimelineEntry) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_cache_loaded().await?;
        TIMELINE_CACHE.with(|cache| cache.borrow_mut().push(entry));
        persist_cache().await
    }

    async fn find_by_date(&self, day: NaiveDate) -> Vec<TimelineEntry> {
        ensure_cache_loaded().await.ok();
        TIMELINE_CACHE.with(|cache| {
            let mut results: Vec<TimelineEntry> = cache.borrow().iter().filter(|e| e.occurred_on.date_naive() == day).cloned().collect();
            results.sort_by_key(|e| e.occurred_on);
            results
        })
    }

    async fn remove(&mut self, id: Uuid) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_cache_loaded().await?;
        TIMELINE_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let pos = cache.iter().position(|e| e.id == id).ok_or_else(|| GameError::Other(format!("No timeline entry with id '{}'", id)))?;
            cache.remove(pos);
            Ok(())
        })?;
        persist_cache().await
    }

    async fn reassign(&mut self, entry_id: Uuid, quest_id: Uuid) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_cache_loaded().await?;
        TIMELINE_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let entry = cache.iter_mut().find(|e| e.id == entry_id).ok_or_else(|| GameError::Other(format!("No timeline entry with id '{}'", entry_id)))?;
            entry.quest_id = quest_id;
            Ok(())
        })?;
        persist_cache().await
    }
}

#[cfg(not(target_arch = "wasm32"))]
#[async_trait::async_trait]
impl TimelineRepository for WasmTimelineRepository {
    async fn record(&mut self, _entry: TimelineEntry) -> Result<(), GameError> { unreachable!() }
    async fn find_by_date(&self, _day: NaiveDate) -> Vec<TimelineEntry> { unreachable!() }
    async fn remove(&mut self, _id: Uuid) -> Result<(), GameError> { unreachable!() }
    async fn reassign(&mut self, _entry_id: Uuid, _quest_id: Uuid) -> Result<(), GameError> { unreachable!() }
}

// ─── Timeline helpers (WASM only) ──────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
pub(crate) async fn ensure_cache_loaded() -> Result<(), GameError> {
    let already_loaded = TIMELINE_CACHE_LOADED.with(|l| *l.borrow());
    if already_loaded { return Ok(()); }

    let cb = TIMELINE_CALLBACKS.with(|c| {
        c.borrow().as_ref().map(|cb| cb.load_timeline.clone()).ok_or_else(|| {
            GameError::Other("Timeline repository callbacks not set. Call setTimelineRepositoryCallbacks().".into())
        })
    })?;

    let this = JsValue::null();
    let promise_val = cb.call0(&this).map_err(|e| GameError::Other(format!("loadTimeline callback threw: {:?}", e)))?;
    let promise = js_sys::Promise::from(promise_val);
    let json_val = wasm_bindgen_futures::JsFuture::from(promise).await.map_err(|e| GameError::Other(format!("loadTimeline callback rejected: {:?}", e)))?;
    let json_str: String = json_val.as_string().ok_or_else(|| GameError::Other("loadTimeline callback must return a string".into()))?;

    let entries: Vec<TimelineEntry> = serde_json::from_str(&json_str).map_err(|e| GameError::Other(e.to_string()))?;
    TIMELINE_CACHE.with(|cache| { *cache.borrow_mut() = entries; });
    TIMELINE_CACHE_LOADED.with(|l| *l.borrow_mut() = true);
    Ok(())
}

#[cfg(target_arch = "wasm32")]
pub(crate) async fn persist_cache() -> Result<(), GameError> {
    let json_str = TIMELINE_CACHE.with(|cache| serde_json::to_string(&*cache.borrow()).map_err(|e| GameError::Other(e.to_string())))?;
    let cb = TIMELINE_CALLBACKS.with(|c| c.borrow().as_ref().map(|cb| cb.save_timeline.clone()).ok_or_else(|| GameError::Other("Timeline repository callbacks not set".into())))?;
    let this = JsValue::null();
    let arg = JsValue::from(&json_str);
    let promise_val = cb.call1(&this, &arg).map_err(|e| GameError::Other(format!("saveTimeline callback threw: {:?}", e)))?;
    wasm_bindgen_futures::JsFuture::from(js_sys::Promise::from(promise_val)).await.map_err(|e| GameError::Other(format!("saveTimeline callback rejected: {:?}", e)))?;
    Ok(())
}

// ─── Combined query exports ────────────────────────────────────────────────

/// Return timeline entries for a specific date as JSON (includes quest info).
#[wasm_bindgen(js_name = getTimelineForDate)]
pub async fn wasm_get_timeline_for_date(year: i32, month: u8, day: u8) -> Result<String, JsError> {
    #[cfg(target_arch = "wasm32")]
    async fn impl_(year: i32, month: u8, day: u8) -> Result<String, JsError> {
        use chrono::NaiveDate;
        use crate::quest_repository;

        quest_repository::ensure_cache_loaded().await.map_err(|e| JsError::new(&e.to_string()))?;
        ensure_cache_loaded().await.map_err(|e| JsError::new(&e.to_string()))?;

        let date = match NaiveDate::from_ymd_opt(year, month as u32, day as u32) {
            Some(d) => d,
            None => return Err(JsError::new(&format!("Invalid date: {}-{:02}-{:02}", year, month, day))),
        };

        let result = quest_repository::quest_internals::QUEST_CACHE.with(|qc| {
            let quests = qc.borrow();
            TIMELINE_CACHE.with(|tc| {
                let borrowed = tc.borrow();
                let mut entries: Vec<&TimelineEntry> = borrowed.iter().filter(|e| e.occurred_on.date_naive() == date).collect();
                entries.sort_by_key(|e| e.occurred_on);

                let timeline: Vec<serde_json::Value> = entries.iter().map(|entry| {
                    let quest_info = quests.iter().find(|q| q.id == entry.quest_id);
                    let points = quest_info.map(|q| q.points).unwrap_or(0);
                    let description = quest_info.map(|q| q.description.as_str()).unwrap_or("");
                    json!({
                        "id": entry.id.to_string(),
                        "questId": entry.quest_id.to_string(),
                        "questTitle": quest_info.map(|q| q.title.as_str()).unwrap_or(""),
                        "occurredOn": entry.occurred_on.to_rfc3339(),
                        "points": points,
                        "description": description,
                    })
                }).collect();

                let total_points: u32 = timeline.iter().filter_map(|e| e.get("points")?.as_u64()).sum::<u64>() as u32;
                json!({ "timeline": timeline, "totalPoints": total_points })
            })
        });

        Ok(serde_json::to_string(&result).map_err(|e| JsError::new(&e.to_string()))?)
    }

    #[cfg(not(target_arch = "wasm32"))]
    async fn impl_(_year: i32, _month: u8, _day: u8) -> Result<String, JsError> {
        Err(JsError::new("getTimelineForDate is only available on WASM"))
    }

    impl_(year, month, day).await
}
