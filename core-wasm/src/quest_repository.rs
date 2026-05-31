//! WASM quest repository adapter that persists quests via JS callbacks.
//!
//! Follows the same pattern as [`WasmJournalAdapter`] — the JS side registers
//! callbacks via [`setQuestRepositoryCallbacks`]; the adapter calls them to
//! load and save quest state from Obsidian's plugin data store.

use std::cell::RefCell;

use chrono::{DateTime, NaiveDate, Utc};
use prompt_yourself_core::domain::entities::game::{GameError, Quest};
use prompt_yourself_core::domain::ports::quest_repository::QuestRepository;
#[cfg(target_arch = "wasm32")]
use serde_json::json;
use wasm_bindgen::prelude::*;

// ─── JS callback types ─────────────────────────────────────────────────────

/// Callbacks that the JS side (Obsidian plugin) must register.
#[allow(dead_code)]
struct QuestCallbacks {
    /// `(json: string) => Promise<void>` — persist the full quest list.
    save_quests: js_sys::Function,
    /// `() => Promise<string>` — load the full quest list (JSON).
    load_quests: js_sys::Function,
}

// ─── Thread-local state ────────────────────────────────────────────────────

thread_local! {
    static CALLBACKS: RefCell<Option<QuestCallbacks>> = const { RefCell::new(None) };
    static QUEST_CACHE: RefCell<Vec<Quest>> = const { RefCell::new(Vec::new()) };
    static CACHE_LOADED: RefCell<bool> = const { RefCell::new(false) };
}

// ─── Re-entrancy guard ─────────────────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
thread_local! {
    static REENTRY_GUARD: RefCell<bool> = const { RefCell::new(false) };
}

#[cfg(target_arch = "wasm32")]
struct ReentryGuard;
#[cfg(target_arch = "wasm32")]
impl ReentryGuard {
    fn try_enter() -> Result<Self, GameError> {
        REENTRY_GUARD.with(|g| {
            let mut guard = g.borrow_mut();
            if *guard {
                return Err(GameError::Other(
                    "Re-entry detected: the quest repository callbacks must not call back \
                     into WASM functions that acquire the chat lock"
                        .to_string(),
                ));
            }
            *guard = true;
            Ok(ReentryGuard)
        })
    }
}
#[cfg(target_arch = "wasm32")]
impl Drop for ReentryGuard {
    fn drop(&mut self) {
        REENTRY_GUARD.with(|g| *g.borrow_mut() = false);
    }
}

// ─── WASM exports ──────────────────────────────────────────────────────────

/// Register JS callbacks for quest persistence.
///
/// `callbacks` must be an object with:
///   - `loadQuests`: `() => Promise<string>` — returns a JSON array of quests
///   - `saveQuests`: `(json: string) => Promise<void>` — persists the quest array
///
/// Must be called before `initChat()`.
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

    CALLBACKS.with(|cb| {
        *cb.borrow_mut() = Some(QuestCallbacks {
            load_quests,
            save_quests,
        });
    });

    // Invalidate the cache so the next access reloads from storage
    CACHE_LOADED.with(|loaded| *loaded.borrow_mut() = false);

    Ok(())
}

// ─── Adapter ────────────────────────────────────────────────────────────────

/// WASM quest repository that delegates persistence to JS callbacks.
pub struct WasmQuestRepository;

#[cfg(target_arch = "wasm32")]
#[async_trait::async_trait(?Send)]
impl QuestRepository for WasmQuestRepository {
    async fn insert(&mut self, quest: Quest) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_cache_loaded().await?;

        QUEST_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            if cache.iter().any(|q| q.title == quest.title) {
                return Err(GameError::Other(format!(
                    "Quest with title '{}' already exists",
                    quest.title
                )));
            }
            cache.push(quest);
            Ok(())
        })?;

        persist_cache().await
    }

    async fn mark_completed(
        &mut self,
        title: &str,
        completed_at: DateTime<Utc>,
    ) -> Result<(), GameError> {
        let _guard = ReentryGuard::try_enter()?;
        ensure_cache_loaded().await?;

        QUEST_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let quest = cache.iter_mut().find(|q| q.title == title).ok_or_else(|| {
                GameError::Other(format!("No quest found with title '{}'", title))
            })?;

            if quest.completed_at.is_some() {
                return Err(GameError::Other(format!(
                    "Quest '{}' is already completed",
                    title
                )));
            }

            quest.completed_at = Some(completed_at);
            Ok(())
        })?;

        persist_cache().await
    }

    async fn find_open(&self) -> Vec<Quest> {
        ensure_cache_loaded().await.ok();
        QUEST_CACHE.with(|cache| {
            cache.borrow().iter().filter(|q| q.completed_at.is_none()).cloned().collect()
        })
    }

    async fn find_completed_at(&self, day: NaiveDate) -> Vec<Quest> {
        ensure_cache_loaded().await.ok();
        QUEST_CACHE.with(|cache| {
            cache.borrow()
                .iter()
                .filter(|q| q.completed_at.is_some_and(|ts| ts.date_naive() == day))
                .cloned()
                .collect()
        })
    }

    async fn exists(&self, title: &str) -> bool {
        ensure_cache_loaded().await.ok();
        QUEST_CACHE.with(|cache| {
            cache.borrow().iter().any(|q| q.title == title)
        })
    }
}

// ─── Native stub ────────────────────────────────────────────────────────────

#[cfg(not(target_arch = "wasm32"))]
#[async_trait::async_trait]
impl QuestRepository for WasmQuestRepository {
    async fn insert(&mut self, _quest: Quest) -> Result<(), GameError> {
        unreachable!("WasmQuestRepository should never be used on native targets")
    }
    async fn mark_completed(
        &mut self,
        _title: &str,
        _completed_at: DateTime<Utc>,
    ) -> Result<(), GameError> {
        unreachable!("WasmQuestRepository should never be used on native targets")
    }
    async fn find_open(&self) -> Vec<Quest> {
        unreachable!("WasmQuestRepository should never be used on native targets")
    }
    async fn find_completed_at(&self, _day: NaiveDate) -> Vec<Quest> {
        unreachable!("WasmQuestRepository should never be used on native targets")
    }
    async fn exists(&self, _title: &str) -> bool {
        unreachable!("WasmQuestRepository should never be used on native targets")
    }
}

/// Read the current quest game state from the repository cache without locking
/// the [`CHAT`](crate::CHAT) mutex. Returns JSON with `openQuests`,
/// `completedQuests`, and `totalPoints`.
#[cfg(target_arch = "wasm32")]
pub async fn get_quest_state_from_cache() -> String {
    // Load from storage if not already cached
    ensure_cache_loaded().await.ok();

    let today = Utc::now().date_naive();

    let state = QUEST_CACHE.with(|cache| {
        let quests = cache.borrow();
        let open_quests: Vec<serde_json::Value> = quests
            .iter()
            .filter(|q| q.completed_at.is_none())
            .map(|q| {
                json!({
                    "title": q.title,
                    "description": q.description,
                    "points": q.points,
                })
            })
            .collect();

        let completed_today: Vec<&Quest> = quests
            .iter()
            .filter(|q| q.completed_at.is_some_and(|ts| ts.date_naive() == today))
            .collect();

        let completed_quests: Vec<serde_json::Value> = completed_today
            .iter()
            .map(|q| {
                json!({
                    "title": q.title,
                    "description": q.description,
                    "points": q.points,
                })
            })
            .collect();

        let total_points: u32 = completed_today.iter().map(|q| q.points).sum();

        json!({
            "openQuests": open_quests,
            "completedQuests": completed_quests,
            "totalPoints": total_points,
        })
    });

    serde_json::to_string(&state).unwrap_or_else(|_| "{}".to_string())
}

/// Native stub (unreachable — only used during WASM builds).
#[cfg(not(target_arch = "wasm32"))]
pub async fn get_quest_state_from_cache() -> String {
    String::new()
}

// ─── Internal helpers (WASM only) ─────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
async fn ensure_cache_loaded() -> Result<(), GameError> {
    let already_loaded = CACHE_LOADED.with(|l| *l.borrow());
    if already_loaded {
        return Ok(());
    }

    let cb = CALLBACKS.with(|c| {
        c.borrow()
            .as_ref()
            .map(|cb| cb.load_quests.clone())
            .ok_or_else(|| {
                GameError::Other(
                    "Quest repository callbacks not set. Call setQuestRepositoryCallbacks() before initChat()."
                        .to_string(),
                )
            })
    })?;

    let this = JsValue::null();
    let promise_val = cb
        .call0(&this)
        .map_err(|e| GameError::Other(format!("loadQuests callback threw: {:?}", e)))?;

    let promise = js_sys::Promise::from(promise_val);
    let future = wasm_bindgen_futures::JsFuture::from(promise);
    let json_val = future
        .await
        .map_err(|e| GameError::Other(format!("loadQuests callback rejected: {:?}", e)))?;

    let json_str: String = json_val.as_string().ok_or_else(|| {
        GameError::Other(
            "loadQuests callback must return a string (JSON array of quests)".to_string(),
        )
    })?;

    let quests: Vec<Quest> =
        serde_json::from_str(&json_str).map_err(|e| GameError::Other(e.to_string()))?;

    QUEST_CACHE.with(|cache| {
        *cache.borrow_mut() = quests;
    });
    CACHE_LOADED.with(|l| *l.borrow_mut() = true);

    Ok(())
}

#[cfg(target_arch = "wasm32")]
async fn persist_cache() -> Result<(), GameError> {

    let json_str = QUEST_CACHE.with(|cache| {
        serde_json::to_string(&*cache.borrow()).map_err(|e| GameError::Other(e.to_string()))
    })?;

    let cb = CALLBACKS.with(|c| {
        c.borrow()
            .as_ref()
            .map(|cb| cb.save_quests.clone())
            .ok_or_else(|| {
                GameError::Other(
                    "Quest repository callbacks not set".to_string(),
                )
            })
    })?;

    let this = JsValue::null();
    let arg = JsValue::from(&json_str);
    let promise_val = cb
        .call1(&this, &arg)
        .map_err(|e| GameError::Other(format!("saveQuests callback threw: {:?}", e)))?;

    let promise = js_sys::Promise::from(promise_val);
    let future = wasm_bindgen_futures::JsFuture::from(promise);
    future
        .await
        .map_err(|e| GameError::Other(format!("saveQuests callback rejected: {:?}", e)))?;

    Ok(())
}


