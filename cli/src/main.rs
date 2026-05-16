use std::io::{self, BufRead, Write};

use clap::Parser;
use prompt_yourself_core::{domain::ports::journal::JournalPort, OpenAiAdapter};

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

    // Load journal
    let journal_adapter = journal::CliJournalAdapter;
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
