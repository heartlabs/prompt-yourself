import { readFileSync, existsSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import 'dotenv/config';
import { chatCompletion, buildInitialMessages } from '../shared/api.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const filePath = process.argv[2];

if (!filePath) {
  console.error('Usage: node src/cli/index.js <path-to-markdown-file>');
  process.exit(1);
}

if (!existsSync(filePath)) {
  console.error(`Error: File not found — ${filePath}`);
  process.exit(1);
}

const apiKey = process.env.DEEPSEEK_API_KEY;
if (!apiKey || apiKey === 'your-api-key-here') {
  console.error('Error: DEEPSEEK_API_KEY is missing or unset in .env');
  process.exit(1);
}

const fileContent = readFileSync(filePath, 'utf-8');

const systemPromptPath = resolve(__dirname, '../shared/system-prompt.md');
const systemPrompt = readFileSync(systemPromptPath, 'utf-8');

const messages = buildInitialMessages(systemPrompt, fileContent);

const rl = createInterface({ input: process.stdin, output: process.stdout });

console.log(`Loaded: ${filePath}`);
console.log('Ask questions about the file. (Ctrl+C to exit)\n');

while (true) {
  const userInput = await rl.question('> ');

  messages.push({ role: 'user', content: userInput });

  try {
    const reply = await chatCompletion({
      apiKey,
      messages,
      maxTokens: 500,
    });
    console.log(`\n${reply}\n`);
    messages.push({ role: 'assistant', content: reply });
  } catch (err) {
    console.error(`\nError: ${err.message}\n`);
  }
}
