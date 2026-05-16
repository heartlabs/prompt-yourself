use std::fs;
use std::path::PathBuf;
use std::time::SystemTime;

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
        Self {
            path: path.into(),
        }
    }
}

#[async_trait::async_trait]
impl JournalPort for CliJournalAdapter {
    async fn load_entries(&self, since: &str) -> Result<Vec<FileEntry>, JournalError> {
        let since_time = parse_iso8601(since);

        if !self.path.exists() {
            return Err(JournalError::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("Path not found — {}", self.path.display()),
            )));
        }

        if self.path.is_dir() {
            Ok(walk_directory(&self.path, since_time))
        } else if self.path.is_file() {
            // Single file: return it if its mtime is after `since`
            let meta = fs::metadata(&self.path)?;
            let mtime = meta.modified().ok();
            if let Some(mtime) = mtime {
                if mtime > since_time {
                    let content = fs::read_to_string(&self.path).ok();
                    let last_modified = format_mtime(mtime);
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
pub(crate) fn walk_directory(dir: &std::path::Path, since: SystemTime) -> Vec<FileEntry> {
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

        if mtime <= since {
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

        let last_modified = format_mtime(mtime);

        results.push(FileEntry {
            path: rel_path,
            content,
            last_modified,
        });
    }

    results
}

/// Parse an ISO 8601 UTC timestamp into a `SystemTime`.
fn parse_iso8601(s: &str) -> SystemTime {
    if s.len() < 20 || !s.ends_with('Z') {
        return std::time::UNIX_EPOCH;
    }

    let year: i64 = s[0..4].parse().unwrap_or(1970);
    let month: u32 = s[5..7].parse().unwrap_or(1);
    let day: u32 = s[8..10].parse().unwrap_or(1);
    let hour: u32 = s[11..13].parse().unwrap_or(0);
    let min: u32 = s[14..16].parse().unwrap_or(0);
    let sec: u32 = s[17..19].parse().unwrap_or(0);

    let days_from_epoch = days_since_epoch(year, month, day);
    let total_secs = days_from_epoch as u64 * 86400
        + (hour as u64 * 3600 + min as u64 * 60 + sec as u64);
    std::time::UNIX_EPOCH + std::time::Duration::from_secs(total_secs)
}

/// Calculate days since Unix epoch (1970-01-01).
fn days_since_epoch(year: i64, month: u32, day: u32) -> i64 {
    let mut days: i64 = 0;
    let mut y = 1970i64;
    while y < year {
        days += if is_leap(y) { 366 } else { 365 };
        y += 1;
    }
    let month_days = if is_leap(year) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    for i in 0..(month as usize - 1) {
        days += month_days[i] as i64;
    }
    days + (day as i64 - 1)
}

/// Format a `SystemTime` as an ISO 8601 string (UTC).
pub(crate) fn format_mtime(time: SystemTime) -> String {
    let duration = time
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = duration.as_secs();
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    let mut y = 1970i64;
    let mut remaining = days as i64;
    loop {
        let days_in_year = if is_leap(y) { 366 } else { 365 };
        if remaining < days_in_year {
            break;
        }
        remaining -= days_in_year;
        y += 1;
    }
    let month_days = if is_leap(y) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m = 0usize;
    for (i, &md) in month_days.iter().enumerate() {
        if remaining < md as i64 {
            m = i;
            break;
        }
        remaining -= md as i64;
    }
    let d = remaining + 1;

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m + 1,
        d,
        hours,
        minutes,
        seconds
    )
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}
