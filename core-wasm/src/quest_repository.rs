use std::cell::RefCell;

#[cfg_attr(not(target_arch = "wasm32"), allow(unused_imports))]
use chrono::{NaiveDate, Utc};
#[cfg_attr(not(target_arch = "wasm32"), allow(unused_imports))]
use prompt_yourself_core::domain::entities::game::{
    GameError, Quest, QuestStatus, TimelineEntry,
};
use prompt_yourself_core::domain::ports::quest_repository::QuestRepository;
use prompt_yourself_core::domain::ports::timeline_repository::TimelineRepository;
#[cfg(target_arch = "wasm32")]
use serde_json::json;
#[cfg_attr(not(target_arch = "wasm32"), allow(unused_imports))]
use uuid::Uuid;
use wasm_bindgen::prelude::*;

// ═══════════════════════════════════════════════════════════════════════════
//  Quest callbacks & state
// ═══════════════════════════════════════════════════════════════════════════

#[allow(dead_code)]
struct QuestCallbacks {
    save_quests: js_sys::Function,
    load_quests: js_sys::Function,
}

thread_local! {
    static QUEST_CALLBACKS: RefCell<Option<QuestCallbacks>> = const { RefCell::new(None) };
    static QUEST_CACHE: RefCell<Vec<Quest>> = const { RefCell::new(Vec::new()) };
    static QUEST_CACHE_LOADED: RefCell<bool> = const { RefCell::new(false) };
}

#[allow(dead_code)]
struct TimelineCallbacks {
    save_timeline: js_sys::Function,
    load_timeline: js_sys::Function,
}

thread_local! {
    static TIMELINE_CALLBACKS: RefCell<Option<TimelineCallbacks>> = const { RefCell::new(None) };
    static TIMELINE_CACHE: RefCell<Vec<TimelineEntry>> = const { RefCell::new(Vec::new()) };
    static TIMELINE_CACHE_LOADED: RefCell<bool> = const { RefCell::new(false) };
}

// Re-entrancy guard
#[cfg(target_arch = "wasm32")]
thread_local! { static REENTRY_GUARD: RefCell<bool> = const { RefCell::new(false) }; }
#[cfg(target_arch = "wasm32")]
struct ReentryGuard;
#[cfg(target_arch = "wasm32")]
impl ReentryGuard {
    fn try_enter() -> Result<Self, GameError> {
        REENTRY_GUARD.with(|g| {
            let mut guard = g.borrow_mut();
            if *guard { return Err(GameError::Other("Re-entry detected".into())); }
            *guard = true; Ok(ReentryGuard)
        })
    }
}
#[cfg(target_arch = "wasm32")]
impl Drop for ReentryGuard { fn drop(&mut self) { REENTRY_GUARD.with(|g| *g.borrow_mut() = false); } }

// ═══════════════════════════════════════════════════════════════════════════
//  WASM exports
// ═══════════════════════════════════════════════════════════════════════════

#[wasm_bindgen(js_name = setQuestRepositoryCallbacks)]
pub fn wasm_set_quest_repository_callbacks(callbacks: &js_sys::Object) -> Result<(), JsError> {
    let load_quests = js_sys::Reflect::get(callbacks, &JsValue::from("loadQuests"))
        .map_err(|_| JsError::new("loadQuests callback missing"))?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| JsError::new("loadQuests must be a function"))?;
    let save_quests = js_sys::Reflect::get(callbacks, &JsValue::from("saveQuests"))
        .map_err(|_| JsError::new("saveQuests callback missing"))?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| JsError::new("saveQuests must be a function"))?;
    QUEST_CALLBACKS.with(|cb| { *cb.borrow_mut() = Some(QuestCallbacks { load_quests, save_quests }); });
    QUEST_CACHE_LOADED.with(|loaded| *loaded.borrow_mut() = false);
    Ok(())
}

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

#[wasm_bindgen(js_name = clearGameData)]
pub fn wasm_clear_game_data() {
    QUEST_CACHE.with(|c| *c.borrow_mut() = Vec::new());
    QUEST_CACHE_LOADED.with(|l| *l.borrow_mut() = false);
    TIMELINE_CACHE.with(|c| *c.borrow_mut() = Vec::new());
    TIMELINE_CACHE_LOADED.with(|l| *l.borrow_mut() = false);
}

// ═══════════════════════════════════════════════════════════════════════════
//  WasmQuestRepository
// ═══════════════════════════════════════════════════════════════════════════

pub struct WasmQuestRepository;

#[cfg(target_arch = "wasm32")]
#[async_trait::async_trait(?Send)]
impl QuestRepository for WasmQuestRepository {
    async fn insert(&mut self, quest: Quest) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_quest_cache_loaded().await?;
        QUEST_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            if cache.iter().any(|q| q.title == quest.title) {
                return Err(GameError::Other(format!("Quest with title '{}' already exists", quest.title)));
            }
            cache.push(quest);
            Ok(())
        })?;
        persist_quest_cache().await
    }

    async fn mark_completed(&mut self, id: Uuid) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_quest_cache_loaded().await?;
        QUEST_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let quest = cache.iter_mut().find(|q| q.id == id).ok_or_else(|| {
                GameError::Other(format!("No quest found with id '{}'", id))
            })?;
            if quest.status == QuestStatus::Completed {
                return Err(GameError::Other(format!("Quest '{}' is already completed", quest.title)));
            }
            quest.status = QuestStatus::Completed;
            Ok(())
        })?;
        persist_quest_cache().await
    }

    async fn find_open(&self) -> Vec<Quest> {
        ensure_quest_cache_loaded().await.ok();
        QUEST_CACHE.with(|cache| {
            cache.borrow().iter().filter(|q| q.status == QuestStatus::Open || q.status == QuestStatus::Pinned).cloned().collect()
        })
    }

    async fn find_pinned(&self) -> Vec<Quest> {
        ensure_quest_cache_loaded().await.ok();
        QUEST_CACHE.with(|cache| cache.borrow().iter().filter(|q| q.status == QuestStatus::Pinned).cloned().collect())
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Quest>, GameError> {
        ensure_quest_cache_loaded().await.ok();
        Ok(QUEST_CACHE.with(|cache| cache.borrow().iter().find(|q| q.id == id).cloned()))
    }

    async fn title_exists(&self, title: &str) -> bool {
        ensure_quest_cache_loaded().await.ok();
        QUEST_CACHE.with(|cache| cache.borrow().iter().any(|q| q.title == title))
    }

    async fn update(&mut self, id: Uuid, quest: Quest) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_quest_cache_loaded().await?;
        QUEST_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let pos = cache.iter().position(|q| q.id == id).ok_or_else(|| {
                GameError::Other(format!("No quest found with id '{}'", id))
            })?;
            let current_title = cache[pos].title.clone();
            if current_title != quest.title && cache.iter().any(|q| q.title == quest.title) {
                return Err(GameError::Other(format!("A quest with title '{}' already exists", quest.title)));
            }
            cache[pos] = quest;
            Ok(())
        })?;
        persist_quest_cache().await
    }
}

#[cfg(not(target_arch = "wasm32"))]
#[async_trait::async_trait]
impl QuestRepository for WasmQuestRepository {
    async fn insert(&mut self, _quest: Quest) -> Result<(), GameError> { unreachable!() }
    async fn mark_completed(&mut self, _id: Uuid) -> Result<(), GameError> { unreachable!() }
    async fn find_open(&self) -> Vec<Quest> { unreachable!() }
    async fn find_pinned(&self) -> Vec<Quest> { unreachable!() }
    async fn find_by_id(&self, _id: Uuid) -> Result<Option<Quest>, GameError> { unreachable!() }
    async fn title_exists(&self, _title: &str) -> bool { unreachable!() }
    async fn update(&mut self, _id: Uuid, _quest: Quest) -> Result<(), GameError> { unreachable!() }
}

// ═══════════════════════════════════════════════════════════════════════════
//  WasmTimelineRepository
// ═══════════════════════════════════════════════════════════════════════════

pub struct WasmTimelineRepository;

#[cfg(target_arch = "wasm32")]
#[async_trait::async_trait(?Send)]
impl TimelineRepository for WasmTimelineRepository {
    async fn record(&mut self, entry: TimelineEntry) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_timeline_cache_loaded().await?;
        TIMELINE_CACHE.with(|cache| cache.borrow_mut().push(entry));
        persist_timeline_cache().await
    }

    async fn find_by_date(&self, day: NaiveDate) -> Vec<TimelineEntry> {
        ensure_timeline_cache_loaded().await.ok();
        TIMELINE_CACHE.with(|cache| {
            let mut results: Vec<TimelineEntry> = cache.borrow().iter().filter(|e| e.occurred_on.date_naive() == day).cloned().collect();
            results.sort_by_key(|e| e.occurred_on);
            results
        })
    }

    async fn remove(&mut self, id: Uuid) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_timeline_cache_loaded().await?;
        TIMELINE_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let pos = cache.iter().position(|e| e.id == id).ok_or_else(|| GameError::Other(format!("No timeline entry with id '{}'", id)))?;
            cache.remove(pos);
            Ok(())
        })?;
        persist_timeline_cache().await
    }

    async fn reassign(&mut self, entry_id: Uuid, quest_id: Uuid) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_timeline_cache_loaded().await?;
        TIMELINE_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let entry = cache.iter_mut().find(|e| e.id == entry_id).ok_or_else(|| GameError::Other(format!("No timeline entry with id '{}'", entry_id)))?;
            entry.quest_id = quest_id;
            Ok(())
        })?;
        persist_timeline_cache().await
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

// ═══════════════════════════════════════════════════════════════════════════
//  Game state JSON
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(target_arch = "wasm32")]
pub async fn get_quest_state_from_cache() -> String {
    ensure_quest_cache_loaded().await.ok();
    ensure_timeline_cache_loaded().await.ok();

    let today = Utc::now().date_naive();

    let state = QUEST_CACHE.with(|qc| {
        let quests = qc.borrow();

        let open_quests: Vec<serde_json::Value> = quests.iter().filter(|q| q.status == QuestStatus::Open).map(|q| {
            json!({ "id": q.id.to_string(), "title": q.title, "description": q.description, "points": q.points })
        }).collect();

        let pinned_quests: Vec<serde_json::Value> = quests.iter().filter(|q| q.status == QuestStatus::Pinned).map(|q| {
            json!({ "id": q.id.to_string(), "title": q.title, "description": q.description, "points": q.points })
        }).collect();

        let timeline: Vec<serde_json::Value> = TIMELINE_CACHE.with(|tc| {
            let borrowed = tc.borrow();
            let mut entries: Vec<&TimelineEntry> = borrowed.iter().filter(|e| e.occurred_on.date_naive() == today).collect();
            entries.sort_by_key(|e| e.occurred_on);

            entries.iter().map(|entry| {
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
            }).collect()
        });

        let total_points: u32 = timeline.iter().filter_map(|e| e.get("points")?.as_u64()).sum::<u64>() as u32;

        json!({ "openQuests": open_quests, "pinnedQuests": pinned_quests, "timeline": timeline, "totalPoints": total_points })
    });

    serde_json::to_string(&state).unwrap_or_else(|_| "{}".to_string())
}

#[cfg(not(target_arch = "wasm32"))]
pub async fn get_quest_state_from_cache() -> String { String::new() }

// ═══════════════════════════════════════════════════════════════════════════
//  Internal helpers
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(target_arch = "wasm32")]
async fn ensure_quest_cache_loaded() -> Result<(), GameError> {
    let already_loaded = QUEST_CACHE_LOADED.with(|l| *l.borrow());
    if already_loaded { return Ok(()); }

    let cb = QUEST_CALLBACKS.with(|c| {
        c.borrow().as_ref().map(|cb| cb.load_quests.clone()).ok_or_else(|| {
            GameError::Other("Quest repository callbacks not set. Call setQuestRepositoryCallbacks() before initChat().".into())
        })
    })?;

    let this = JsValue::null();
    let promise_val = cb.call0(&this).map_err(|e| GameError::Other(format!("loadQuests callback threw: {:?}", e)))?;
    let promise = js_sys::Promise::from(promise_val);
    let json_val = wasm_bindgen_futures::JsFuture::from(promise).await.map_err(|e| GameError::Other(format!("loadQuests callback rejected: {:?}", e)))?;
    let json_str: String = json_val.as_string().ok_or_else(|| GameError::Other("loadQuests callback must return a string".into()))?;

    let quests: Vec<Quest> = serde_json::from_str(&json_str).map_err(|e| GameError::Other(e.to_string()))?;
    QUEST_CACHE.with(|cache| { *cache.borrow_mut() = quests; });
    QUEST_CACHE_LOADED.with(|l| *l.borrow_mut() = true);
    Ok(())
}

#[cfg(target_arch = "wasm32")]
async fn persist_quest_cache() -> Result<(), GameError> {
    let json_str = QUEST_CACHE.with(|cache| serde_json::to_string(&*cache.borrow()).map_err(|e| GameError::Other(e.to_string())))?;
    let cb = QUEST_CALLBACKS.with(|c| c.borrow().as_ref().map(|cb| cb.save_quests.clone()).ok_or_else(|| GameError::Other("Quest repository callbacks not set".into())))?;
    let this = JsValue::null();
    let arg = JsValue::from(&json_str);
    let promise_val = cb.call1(&this, &arg).map_err(|e| GameError::Other(format!("saveQuests callback threw: {:?}", e)))?;
    wasm_bindgen_futures::JsFuture::from(js_sys::Promise::from(promise_val)).await.map_err(|e| GameError::Other(format!("saveQuests callback rejected: {:?}", e)))?;
    Ok(())
}

#[cfg(target_arch = "wasm32")]
async fn ensure_timeline_cache_loaded() -> Result<(), GameError> {
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
async fn persist_timeline_cache() -> Result<(), GameError> {
    let json_str = TIMELINE_CACHE.with(|cache| serde_json::to_string(&*cache.borrow()).map_err(|e| GameError::Other(e.to_string())))?;
    let cb = TIMELINE_CALLBACKS.with(|c| c.borrow().as_ref().map(|cb| cb.save_timeline.clone()).ok_or_else(|| GameError::Other("Timeline repository callbacks not set".into())))?;
    let this = JsValue::null();
    let arg = JsValue::from(&json_str);
    let promise_val = cb.call1(&this, &arg).map_err(|e| GameError::Other(format!("saveTimeline callback threw: {:?}", e)))?;
    wasm_bindgen_futures::JsFuture::from(js_sys::Promise::from(promise_val)).await.map_err(|e| GameError::Other(format!("saveTimeline callback rejected: {:?}", e)))?;
    Ok(())
}
