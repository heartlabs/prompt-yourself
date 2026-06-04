//! Shared re-entrancy guard used by both repository adapters.

#[cfg(target_arch = "wasm32")]
use std::cell::RefCell;
use prompt_yourself_core::domain::entities::game::GameError;

#[cfg(target_arch = "wasm32")]
thread_local! {
    static REENTRY_GUARD: RefCell<bool> = const { RefCell::new(false) };
}

pub struct ReentryGuard;

#[cfg(target_arch = "wasm32")]
impl ReentryGuard {
    pub fn try_enter() -> Result<Self, GameError> {
        REENTRY_GUARD.with(|g| {
            let mut guard = g.borrow_mut();
            if *guard {
                return Err(GameError::Other("Re-entry detected".into()));
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

#[cfg(not(target_arch = "wasm32"))]
impl ReentryGuard {
    pub fn try_enter() -> Result<Self, GameError> {
        Ok(ReentryGuard)
    }
}
