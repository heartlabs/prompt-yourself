use std::fs;
use std::io::{self, BufRead, Write};
use std::path::Path;

use clap::Parser;
use prompt_yourself_core::domain::ports::journal::{JournalError, JournalPort};
use prompt_yourself_core::OpenAiAdapter;
use prompt_yourself_core::yaml_producer::{produce_yaml, FileEntry};
use walkdir::WalkDir;

// ─── CLI args ───────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "prompt-yourself", about = "Ask questions about files/folders")]
struct Args {
    /// Path to a markdown file or folder
    path: String,
}

// ─── CLI journal adapter ────────────────────────────────────────────────────

/// Adapter that loads a journal from the native filesystem.
struct CliJournalAdapter;

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

// ─── Text extensions (same set as JS original) ──────────────────────────────

const TEXT_EXTENSIONS: &[&str] = &[
    ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".csv", ".html", ".css", ".scss",
    ".xml", ".log",
];

fn is_text_file(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| {
            let ext = format!(".{}", ext.to_lowercase());
            TEXT_EXTENSIONS.contains(&ext.as_str())
        })
        .unwrap_or(false)
}

/// Walk a directory recursively and collect file entries.
fn walk_directory(dir: &Path) -> Vec<FileEntry> {
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

// ─── Main ───────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .ok()
        .filter(|k| k != "your-api-key-here")
        .unwrap_or_else(|| {
            eprintln!("Error: DEEPSEEK_API_KEY is missing or unset in .env");
            std::process::exit(1);
        });

    const MODEL: &str = "deepseek-chat";
    const API_BASE: &str = "https://api.deepseek.com";

    // Load journal
    let journal_adapter = CliJournalAdapter;
    let journal_yaml = journal_adapter.load_journal(&args.path)?;

    // Build OpenAI adapter and chat, then seed the document context
    let openai_adapter = OpenAiAdapter::new(api_key, API_BASE.to_string(), MODEL.to_string());
    let mut chat = prompt_yourself_core::api::chat::Chat::new(
        Box::new(openai_adapter),
        prompt_yourself_core::api::chat::SYSTEM_PROMPT.to_string(),
    );
    chat.set_document_context(&journal_yaml);

    println!("Ask questions about the content. (Ctrl+C to exit)\n");

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();

    loop {
        write!(writer, "> ")?;
        writer.flush()?;

        let mut input = String::new();
        reader.read_line(&mut input)?;
        let input = input.trim().to_string();

        if input.is_empty() {
            continue;
        }

        match chat.user_message(input).await {
            Ok(reply) => {
                println!("\n{reply}\n");
            }
            Err(e) => {
                eprintln!("\nError: {e}\n");
            }
        }
    }
}
