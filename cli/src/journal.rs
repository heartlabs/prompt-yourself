use prompt_yourself_core::domain::ports::journal::JournalError;
use walkdir::WalkDir;

use prompt_yourself_core::yaml_producer::FileEntry;

use prompt_yourself_core::yaml_producer::produce_yaml;

use std::io;
use std::path::Path;

use prompt_yourself_core::domain::ports::journal::JournalPort;

use std::fs;

/// Adapter that loads a journal from the native filesystem.
pub(crate) struct CliJournalAdapter;

impl JournalPort for CliJournalAdapter {
    fn load_journal(&self, path: &str) -> Result<String, JournalError> {
        let input_path = Path::new(path);

        if !input_path.exists() {
            return Err(JournalError::Io(io::Error::new(
                io::ErrorKind::NotFound,
                format!("Path not found — {path}"),
            )));
        }

        let (yaml, label) = if input_path.is_file() {
            let content = fs::read_to_string(input_path)?;
            (content, format!("File: {path}"))
        } else if input_path.is_dir() {
            let files = walk_directory(input_path);
            let yaml = produce_yaml(&files);
            (yaml, format!("Folder: {path} ({} files)", files.len()))
        } else {
            return Err(JournalError::Io(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("Not a file or directory — {path}"),
            )));
        };

        eprintln!("{label}");
        Ok(yaml)
    }
}

pub(crate) const TEXT_EXTENSIONS: &[&str] = &[
    ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".csv", ".html", ".css", ".scss", ".xml",
    ".log",
];

pub(crate) fn is_text_file(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| {
            let ext = format!(".{}", ext.to_lowercase());
            TEXT_EXTENSIONS.contains(&ext.as_str())
        })
        .unwrap_or(false)
}

/// Walk a directory recursively and collect file entries.
pub(crate) fn walk_directory(dir: &Path) -> Vec<FileEntry> {
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
        });
    }

    results
}
