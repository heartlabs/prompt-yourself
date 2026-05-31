use std::io::{self, BufRead, Write};

use clap::Parser;
use prompt_yourself_core::domain::ports::openai::ChatMessage;
use prompt_yourself_core::OpenAiAdapter;
use prompt_yourself_core::InMemoryQuestRepository;

// ─── CLI args ───────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "prompt-yourself", about = "Ask questions about files/folders")]
struct Args {
    /// Path to a markdown file or folder
    path: String,
}

// ─── CLI journal adapter ────────────────────────────────────────────────────

mod journal;

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

    // Build adapters and chat
    let openai_adapter = OpenAiAdapter::new(api_key, API_BASE.to_string(), MODEL.to_string());
    let journal_adapter = journal::CliJournalAdapter::new(&args.path);

    let mut chat = prompt_yourself_core::api::chat::Chat::new(
        Box::new(openai_adapter),
        Box::new(journal_adapter),
        Box::new(InMemoryQuestRepository::new()),
    );

    // Load the initial document context (loads ALL files since epoch)
    let file_count = chat.load_initial_context().await?;
    eprintln!("Folder: {} ({} files)", args.path, file_count);

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
            Ok(messages) => {
                for msg in &messages {
                    match msg {
                        ChatMessage::Assistant {
                            content: Some(text),
                            ..
                        } => {
                            println!("\n{text}\n");
                        }
                        ChatMessage::Tool { content, .. } => {
                            println!("  ⚡ {content}\n");
                        }
                        _ => {}
                    }
                }
            }
            Err(e) => {
                eprintln!("\nError: {e}\n");
            }
        }
    }
}
