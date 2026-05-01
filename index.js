import { readFileSync, existsSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';
import OpenAI from 'openai';
import 'dotenv/config';

const filePath = process.argv[2];

if (!filePath) {
  console.error('Usage: node index.js <path-to-markdown-file>');
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

const client = new OpenAI({
  apiKey,
  baseURL: 'https://api.deepseek.com',
});

const systemPrompt = readFileSync('system-prompt.md', 'utf-8');

const messages = [
  { role: 'system', content: systemPrompt },
  {
    role: 'user',
    content: `Here is the document to reference:

${fileContent}`,
  },
];

const rl = createInterface({ input: process.stdin, output: process.stdout });

console.log(`Loaded: ${filePath}`);
console.log('Ask questions about the file. (Ctrl+C to exit)\n');

while (true) {
  const userInput = await rl.question('> ');

  messages.push({ role: 'user', content: userInput });

  const response = await client.chat.completions.create({
    model: 'deepseek-chat',
    messages,
    max_tokens: 500,
  });

  const reply = response.choices[0].message.content;
  console.log(`\n${reply}\n`);

  messages.push({ role: 'assistant', content: reply });
}
