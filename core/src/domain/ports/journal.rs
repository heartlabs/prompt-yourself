//! Driven port for loading file entries from a journal (directory / file listing).
//!
//! This module defines the [`JournalPort`] trait and its associated [`JournalError`].

use std::io;

use crate::yaml_producer::FileEntry;

// ─── Port ───────────────────────────────────────────────────────────────────

/// Driven port for loading file entries, typically from a directory on disk.
///
/// Implementations handle platform-specific file access (native fs for CLI,
/// Obsidian vault APIs for the plugin). The path is configured at construction
/// and is not part of the trait interface.
///
/// Each entry includes the relative path, full file content, and a UTC
/// modification timestamp.
///
/// The `since` parameter is a [`chrono::DateTime<chrono::Utc>`][chrono::DateTime]
/// — pass [`DateTime::UNIX_EPOCH`] to load every file.
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
pub trait JournalPort: Send {
    /// Return all file entries whose `last_modified` is strictly after `since`.
    ///
    /// `since` is a UTC timestamp. Pass [`DateTime::UNIX_EPOCH`] to load every file.
    async fn load_entries(
        &self,
        since: &chrono::DateTime<chrono::Utc>,
    ) -> Result<Vec<FileEntry>, JournalError>;
}

// ─── Error type ─────────────────────────────────────────────────────────────

/// Errors that can occur when loading a journal.
#[derive(Debug, thiserror::Error)]
pub enum JournalError {
    /// An I/O error occurred.
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),

    /// A non-I/O error (e.g. a JS callback threw).
    #[error("{0}")]
    Other(String),
}

impl From<String> for JournalError {
    fn from(s: String) -> Self {
        JournalError::Other(s)
    }
}
