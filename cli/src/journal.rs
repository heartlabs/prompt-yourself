use std::fs;
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use prompt_yourself_core::domain::ports::journal::{JournalError, JournalPort};
use prompt_yourself_core::yaml_producer::FileEntry;
use walkdir::WalkDir;

/// Adapter that loads file entries from the native filesystem.
///
/// The path is set at construction time and is not part of the trait interface.
pub(crate) struct CliJournalAdapter {
    path: PathBuf,
}

impl CliJournalAdapter {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
}

#[async_trait::async_trait]
impl JournalPort for CliJournalAdapter {
    async fn load_entries(&self, since: &DateTime<Utc>) -> Result<Vec<FileEntry>, JournalError> {
        if !self.path.exists() {
            return Err(JournalError::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("Path not found — {}", self.path.display()),
            )));
        }

        if self.path.is_dir() {
            Ok(walk_directory(&self.path, *since))
        } else if self.path.is_file() {
            // Single file: return it if its mtime is after `since`
            let meta = fs::metadata(&self.path)?;
            let mtime = meta.modified().ok();
            if let Some(mtime) = mtime {
                let mtime_dt: DateTime<Utc> = mtime.into();
                if mtime_dt > *since {
                    let content = fs::read_to_string(&self.path).ok();
                    let last_modified = Some(mtime_dt);
                    return Ok(vec![FileEntry {
                        path: self
                            .path
                            .file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_string(),
                        content,
                        last_modified,
                    }]);
                }
            }
            Ok(Vec::new())
        } else {
            Err(JournalError::Io(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("Not a file or directory — {}", self.path.display()),
            )))
        }
    }
}

pub(crate) const TEXT_EXTENSIONS: &[&str] = &[
    ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".csv", ".html", ".css", ".scss", ".xml",
    ".log",
];

pub(crate) fn is_text_file(path: &std::path::Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| {
            let ext = format!(".{}", ext.to_lowercase());
            TEXT_EXTENSIONS.contains(&ext.as_str())
        })
        .unwrap_or(false)
}

/// Walk a directory recursively and collect file entries modified after `since`.
pub(crate) fn walk_directory(dir: &std::path::Path, since: DateTime<Utc>) -> Vec<FileEntry> {
    let mut results = Vec::new();

    for entry in WalkDir::new(dir)
        .into_iter()
        .filter_entry(|e| {
            let name = e.file_name().to_str().unwrap_or("");
            !name.starts_with('.') && name != "node_modules"
        })
        .filter_map(|e| e.ok())
    {
        if !entry.file_type().is_file() {
            continue;
        }

        let abs_path = entry.path();

        // Check mtime
        let mtime = match fs::metadata(abs_path).ok().and_then(|m| m.modified().ok()) {
            Some(t) => t,
            None => continue,
        };
        let mtime_dt: DateTime<Utc> = mtime.into();

        if mtime_dt <= since {
            continue;
        }

        let rel_path = abs_path
            .strip_prefix(dir)
            .unwrap_or(abs_path)
            .to_string_lossy()
            .replace('\\', "/");

        let content = if is_text_file(abs_path) {
            fs::read_to_string(abs_path).ok()
        } else {
            None
        };

        results.push(FileEntry {
            path: rel_path,
            content,
            last_modified: Some(mtime_dt),
        });
    }

    results
}
