use std::fs;
use std::io::{self, BufRead, Write};
use std::path::Path;

use clap::Parser;
use prompt_yourself_core::openai::{ChatMessage, Role};
use prompt_yourself_core::yaml_producer::{produce_yaml, FileEntry};
use prompt_yourself_core::build_initial_messages;
use walkdir::WalkDir;

// ─── CLI args ───────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "prompt-yourself", about = "Ask questions about files/folders")]
struct Args {
    /// Path to a markdown file or folder
    path: String,

    /// Maximum tokens in the response
    #[arg(long, default_value = "500")]
    max_tokens: u32,
}

// ─── Text extensions (same set as JS original) ──────────────────────────────

const TEXT_EXTENSIONS: &[&str] = &[
    ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".csv",".html", ".css", ".scss",
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
            // Skip hidden files/dirs and node_modules
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
    let input_path = Path::new(&args.path);

    if !input_path.exists() {
        eprintln!("Error: Path not found — {}", args.path);
        std::process::exit(1);
    }

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .ok()
        .filter(|k| k != "your-api-key-here")
        .unwrap_or_else(|| {
            eprintln!("Error: DEEPSEEK_API_KEY is missing or unset in .env");
            std::process::exit(1);
        });

    // Produce document content
    let (document_content, label) = if input_path.is_file() {
        let content = fs::read_to_string(input_path)?;
        (content, format!("File: {}", args.path))
    } else if input_path.is_dir() {
        let files = walk_directory(input_path);
        let yaml = produce_yaml(&files);
        (yaml, format!("Folder: {} ({} files)", args.path, files.len()))
    } else {
        eprintln!("Error: Not a file or directory — {}", args.path);
        std::process::exit(1);
    };

    let mut messages = build_initial_messages(&document_content);

    const MODEL: &str = "deepseek-chat";

    println!("{label}");
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

        messages.push(ChatMessage {
            role: Role::User,
            content: input,
        });

        match prompt_yourself_core::openai::chat_completion(
            &api_key,
            "https://api.deepseek.com",
            MODEL,
            messages.clone(),
            args.max_tokens,
        )
        .await
        {
            Ok(reply) => {
                println!("\n{reply}\n");
                messages.push(ChatMessage {
                    role: Role::Assistant,
                    content: reply,
                });
            }
            Err(e) => {
                eprintln!("\nError: {e}\n");
            }
        }
    }
}
