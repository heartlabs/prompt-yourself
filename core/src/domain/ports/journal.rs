//! Driven port for loading a journal (directory / file listing) as YAML.
//!
//! This module defines the [`JournalPort`] trait and its associated [`JournalError`].

use std::io;

// ─── Port ───────────────────────────────────────────────────────────────────

/// Driven port for loading a journal from a path and returning it as YAML.
///
/// Implementations handle platform-specific file access (native fs for CLI,
/// Obsidian vault APIs for the plugin). Construction is outside the trait.
pub trait JournalPort: Send {
    /// Load the journal from the given path and produce a YAML string.
    fn load_journal(&self, path: &str) -> Result<String, JournalError>;
}

// ─── Error type ─────────────────────────────────────────────────────────────

/// Errors that can occur when loading a journal.
#[derive(Debug, thiserror::Error)]
pub enum JournalError {
    /// An I/O error occurred.
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
}
