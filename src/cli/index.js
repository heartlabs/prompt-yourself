import { readFileSync, existsSync, statSync, readdirSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, relative, join, sep } from 'node:path';
import 'dotenv/config';
import { chatCompletion, buildInitialMessages } from './api.js';
import { produceYaml } from '../shared/yaml-producer.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ─── Helpers ─────────────────────────────────────────────────────────────────

const TEXT_EXTENSIONS = new Set([
  '.md', '.txt', '.json', '.yaml', '.yml', '.toml', '.csv',
  '.js', '.ts', '.jsx', '.tsx', '.py', '.rb', '.go', '.rs',
  '.html', '.css', '.scss', '.xml', '.svg', '.env',
  '.cfg', '.ini', '.conf', '.log',
]);

/**
 * Walk a directory recursively and collect files.
 * Binary files get content: null.
 *
 * @param {string} dir        – absolute path to walk
 * @param {string} root       – absolute root for relative paths
 * @returns {Array<{path:string, content:string|null}>}
 */
function walkDirectory(dir, root) {
  const results = [];

  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return results; // skip unreadable dirs
  }

  for (const entry of entries) {
    const absolutePath = join(dir, entry.name);

    // Skip hidden files/dirs (dotfiles), node_modules
    if (entry.name.startsWith('.')) continue;
    if (entry.name === 'node_modules') continue;

    if (entry.isDirectory()) {
      results.push(...walkDirectory(absolutePath, root));
    } else if (entry.isFile()) {
      const relPath = relative(root, absolutePath);
      // Normalize to forward slashes
      const normalizedPath = relPath.split(sep).join('/');

      const dotIdx = entry.name.lastIndexOf('.');
      const ext = dotIdx !== -1 ? entry.name.slice(dotIdx).toLowerCase() : '';

      let content;
      if (TEXT_EXTENSIONS.has(ext) || isLikelyText(absolutePath)) {
        try {
          content = readFileSync(absolutePath, 'utf-8');
        } catch {
          content = null; // binary or unreadable
        }
      } else {
        content = null; // binary file
      }

      results.push({ path: normalizedPath, content });
    }
  }

  return results;
}

/**
 * Quick heuristic: attempt to read a few bytes as UTF-8.
 * If it looks like binary, treat as null.
 *
 * @param {string} filePath
 * @returns {boolean}
 */
function isLikelyText(filePath) {
  try {
    const buf = readFileSync(filePath);
    // Check for null bytes — strong indicator of binary content
    for (let i = 0; i < Math.min(buf.length, 4096); i++) {
      if (buf[i] === 0) return false;
    }
    return true;
  } catch {
    return false;
  }
}

// ─── Main ────────────────────────────────────────────────────────────────────

const inputPath = process.argv[2];

if (!inputPath) {
  console.error('Usage: node src/cli/index.js <path-to-markdown-file-or-folder>');
  process.exit(1);
}

if (!existsSync(inputPath)) {
  console.error(`Error: Path not found — ${inputPath}`);
  process.exit(1);
}

const apiKey = process.env.DEEPSEEK_API_KEY;
if (!apiKey || apiKey === 'your-api-key-here') {
  console.error('Error: DEEPSEEK_API_KEY is missing or unset in .env');
  process.exit(1);
}

const systemPromptPath = resolve(__dirname, '../shared/system-prompt.md');
const systemPrompt = readFileSync(systemPromptPath, 'utf-8');

const stat = statSync(inputPath);

/** @type {string} */
let documentContent;
let label;

if (stat.isFile()) {
  // ── Single file (existing behavior) ──────────────────────────────────────
  documentContent = readFileSync(inputPath, 'utf-8');
  label = `File: ${inputPath}`;
} else if (stat.isDirectory()) {
  // ── Folder – walk recursively, produce YAML ──────────────────────────────
  const root = inputPath;
  const files = walkDirectory(root, root);
  documentContent = produceYaml(files);
  label = `Folder: ${inputPath} (${files.length} files)`;
} else {
  console.error(`Error: Not a file or directory — ${inputPath}`);
  process.exit(1);
}

const messages = buildInitialMessages(systemPrompt, documentContent);

const rl = createInterface({ input: process.stdin, output: process.stdout });

console.log(label);
console.log('Ask questions about the content. (Ctrl+C to exit)\n');

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
