/*
 * Prompt Yourself – Obsidian Plugin
 *
 * Side panel chat that uses the DeepSeek API to answer questions about a vault folder.
 *
 * Core logic is implemented in Rust and compiled to WASM. The Rust `Chat` calls a JS
 * callback (`setLoadEntriesCallback`) to load file entries — from the core's perspective
 * there is zero difference between CLI and Obsidian.
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 * Re-entrancy warning
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * The `loadEntries` callback (registered with `setLoadEntriesCallback`) is called
 * from Rust every time a new user message is sent. The callback MUST NOT call any
 * WASM function that acquires the chat lock (e.g. `chatCompletion`,
 * `loadInitialContext`, `resetChat`), or a "Re-entry detected" error will be thrown.
 *
 * The callback is a pure data-fetching function — it reads the vault, filters by
 * mtime, and returns a JSON string. No WASM calls.
 */

import { Plugin, ItemView, PluginSettingTab, Setting, MarkdownRenderer } from 'obsidian';
import { initSync, setApiKey, setSystemPrompt, setLoadEntriesCallback, initChat, loadInitialContext, chatCompletion } from './core_wasm.js';
import wasmBytes from './core_wasm_bg.wasm';

// ─── Constants ───────────────────────────────────────────────────────────────

const TEXT_EXTENSIONS = new Set([
  '.md', '.txt', '.json', '.yaml', '.yml', '.toml', '.csv',
  '.html', '.css', '.scss', '.xml', '.log',
]);

const VIEW_TYPE = 'prompt-yourself-view';
const CHAT_MODEL = 'deepseek-chat';

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Convert milliseconds since epoch to an ISO 8601 UTC timestamp string.
 */
function msToIso8601(ms) {
  const d = new Date(ms);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  const h = String(d.getUTCHours()).padStart(2, '0');
  const min = String(d.getUTCMinutes()).padStart(2, '0');
  const s = String(d.getUTCSeconds()).padStart(2, '0');
  return `${y}-${m}-${day}T${h}:${min}:${s}Z`;
}

// ─── View (side panel) ───────────────────────────────────────────────────────

class PromptYourselfView extends ItemView {
  constructor(leaf, plugin) {
    super(leaf);
    this.plugin = plugin;
  }

  getViewType() {
    return VIEW_TYPE;
  }

  getDisplayText() {
    return 'Prompt Yourself';
  }

  getIcon() {
    return 'message-square';
  }

  async onOpen() {
    const container = this.containerEl.children[1];
    container.empty();
    container.addClass('prompt-yourself-container');

    // Selected folder label
    this.folderLabelEl = container.createEl('div', { cls: 'file-label' });
    this.updateFolderLabel();

    // Chat area
    this.chatAreaEl = container.createEl('div', { cls: 'chat-area' });

    // Input row
    const inputRow = container.createEl('div', { cls: 'input-row' });

    this.inputEl = inputRow.createEl('input', {
      type: 'text',
      placeholder: 'Ask a question…',
    });

    this.sendBtn = inputRow.createEl('button', { text: 'Send' });

    this.inputEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') this.handleSend();
    });
    this.sendBtn.addEventListener('click', () => this.handleSend());

    // Load the folder
    await this.loadFolder();
  }

  updateFolderLabel() {
    const path = this.plugin.settings.folderPath;
    if (!path) {
      this.folderLabelEl.setText('📁 (select a folder in settings)');
    } else {
      this.folderLabelEl.setText('📁 ' + path);
    }
  }

  /**
   * Build the JS callback that the Rust core calls via `JournalPort::load_entries`.
   *
   * The callback receives a millisecond timestamp (Unix epoch) and must return a
   * Promise<string> — a JSON array of `{path, content, lastModified}` objects
   * for every file whose mtime is strictly after `sinceMs`.
   * `lastModified` must be an ISO 8601 string so chrono can deserialize it.
   *
   * ⚠️ This callback MUST NOT call any WASM function that locks the chat
   * (e.g. chatCompletion, loadInitialContext) — see re-entrancy doc.
   */
  buildLoadEntriesCallback() {
    const folderPath = this.plugin.settings.folderPath;
    const app = this.app;

    return async (sinceMs) => {
      let folder;
      if (folderPath === '' || folderPath === '/') {
        folder = app.vault.getRoot();
      } else {
        folder = app.vault.getAbstractFileByPath(folderPath);
      }

      if (!folder || !folder.children) return '[]';

      const results = [];

      // Normalise rootPath
      const prefix = folderPath ? folderPath.replace(/^\/+|\/+$/g, '') : '';

      const walk = async (children) => {
        for (const child of children) {
          if (child.name.startsWith('.')) continue;
          if (child.name === 'node_modules') continue;

          if (child.children) {
            await walk(child.children);
          } else {
            // Relative path
            const childAbs = child.path.replace(/^\//, '');
            let relPath;
            if (!prefix) {
              relPath = childAbs;
            } else if (childAbs === prefix) {
              relPath = '';
            } else if (childAbs.startsWith(prefix + '/')) {
              relPath = childAbs.slice(prefix.length + 1);
            } else {
              relPath = childAbs;
            }

            // mtime filter
            const mtimeMs = child.stat && child.stat.mtime;
            if (sinceMs !== null && mtimeMs !== null && mtimeMs <= sinceMs) {
              continue;
            }

            // Content
            const dotIdx = child.name.lastIndexOf('.');
            const ext = dotIdx !== -1 ? child.name.slice(dotIdx).toLowerCase() : '';
            let content = null;
            if (TEXT_EXTENSIONS.has(ext)) {
              try {
                content = await app.vault.read(child);
                content = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
              } catch (_) {
                content = null;
              }
            }

            const lastModified = mtimeMs != null ? msToIso8601(mtimeMs) : null;
            results.push({ path: relPath, content, lastModified });
          }
        }
      };

      await walk(folder.children);

      if (results.length > 0) {
        console.log(
          `[prompt-yourself] loadEntries(sinceMs=${sinceMs}) returned ${results.length} file(s):`,
          results.map(r => `${r.path} (${r.lastModified ?? '?'})`).join(', ')
        );
      }

      return JSON.stringify(results);
    };
  }

  async loadFolder() {
    const folderPath = this.plugin.settings.folderPath;
    if (folderPath === undefined) return;

    // Reset the chat panel UI
    this.chatAreaEl.empty();
    this.updateFolderLabel();

    // Register the loadEntries callback BEFORE initChat or any WASM calls
    const callback = this.buildLoadEntriesCallback();
    setLoadEntriesCallback(callback);

    const apiKey = this.plugin.settings.apiKey;
    if (apiKey && apiKey !== 'your-api-key-here') {
      try {
        // Initialise the Rust-side Chat (system prompt + API config).
        // The journal adapter is WasmJournalAdapter which calls the JS callback above.
        initChat(CHAT_MODEL);
        // Load every file (since epoch) — the callback handles the vault scan.
        const fileCount = await loadInitialContext();

        this.addMessage('system', 'Loaded folder "' + (folderPath || '/') + '" (' + fileCount + ' files). Ask away!');
      } catch (e) {
        this.addMessage('system', '⚠️ Failed to initialise chat: ' + e.message);
      }
    } else {
      this.addMessage('system', '⚠️ Please set your DeepSeek API key in Plugin Settings.');
    }
  }

  async handleSend() {
    const text = this.inputEl.value.trim();
    if (!text) return;

    const apiKey = this.plugin.settings.apiKey;
    if (!apiKey || apiKey === 'your-api-key-here') {
      this.addMessage('system', '⚠️ Please set your DeepSeek API key in Plugin Settings.');
      return;
    }

    if (this.plugin.settings.folderPath === undefined) {
      this.addMessage('system', '⚠️ Select a folder in Plugin Settings first.');
      return;
    }

    this.addMessage('user', text);
    this.inputEl.value = '';
    this.setLoading(true);

    try {
      // chatCompletion calls user_message internally, which:
      //   1. Calls loadEntries(since_last_check) via the JS callback
      //   2. Injects "Note: File ... updated" messages for any changes
      //   3. Runs the tool-call loop (assistant replies + tool executions)
      //   4. Returns JSON array of all new messages (assistant + tool)
      const json = await chatCompletion(text);
      const messages = JSON.parse(json);
      for (const msg of messages) {
        if (msg.role === 'assistant' && msg.content) {
          this.addMessage('assistant', msg.content);
        } else if (msg.role === 'tool') {
          this.addMessage('tool', msg.content);
        }
      }
    } catch (err) {
      this.addMessage('system', '❌ Error: ' + err.message);
    } finally {
      this.setLoading(false);
    }
  }

  addMessage(role, content) {
    const msgEl = this.chatAreaEl.createEl('div', {
      cls: 'message ' + role,
    });

    if (role === 'assistant' || role === 'user') {
      MarkdownRenderer.render(this.app, content, msgEl, '/', this);
    } else {
      msgEl.setText(content);
    }

    this.chatAreaEl.scrollTo(0, this.chatAreaEl.scrollHeight);
    return msgEl;
  }

  setLoading(loading) {
    this.inputEl.disabled = loading;
    this.sendBtn.disabled = loading;
    this.sendBtn.setText(loading ? '…' : 'Send');
  }

  async onClose() {
    // no-op
  }
}

// ─── Plugin settings ─────────────────────────────────────────────────────────

const DEFAULT_SETTINGS = {
  apiKey: '',
  folderPath: '',
  systemPromptPath: '/Users/neidhartorlich/dev/prompt-yourself/core/resources/system-prompt.md',
};

class PromptYourselfSettingTab extends PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display() {
    const { containerEl } = this;
    containerEl.empty();

    containerEl.createEl('h2', { text: 'Prompt Yourself Settings' });

    new Setting(containerEl)
      .setName('DeepSeek API Key')
      .setDesc('Your DeepSeek API key. Get one at https://platform.deepseek.com/api_keys')
      .addText((text) =>
        text
          .setPlaceholder('sk-...')
          .setValue(this.plugin.settings.apiKey)
          .onChange(async (value) => {
            this.plugin.settings.apiKey = value.trim();
            await this.plugin.saveSettings();
            if (this.plugin.settings.apiKey) {
              setApiKey(this.plugin.settings.apiKey);
            }
          })
      );

    containerEl.createEl('h3', { text: 'Vault Folder' });

    new Setting(containerEl)
      .setName('Folder')
      .setDesc(
        'Choose which vault folder to use as context. ' +
        'All text files inside are bundled into a YAML document for the AI.'
      )
      .addDropdown((dropdown) => {
        const allFiles = this.app.vault.getAllLoadedFiles();
        const pathSet = new Set();
        for (const f of allFiles) {
          if (f.children) {
            const p = f.path === '/' ? '' : f.path;
            pathSet.add(p);
          }
        }
        const folders = Array.from(pathSet).sort();

        dropdown.addOption('', 'Whole vault');
        for (const p of folders) {
          dropdown.addOption(p, p || '/');
        }

        dropdown.setValue(this.plugin.settings.folderPath);

        dropdown.onChange(async (value) => {
          this.plugin.settings.folderPath = value;
          await this.plugin.saveSettings();

          const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE);
          if (leaves.length > 0) {
            const view = leaves[0].view;
            if (view && view.loadFolder) {
              await view.loadFolder();
            }
          }
        });
      });
  }
}

// ─── Plugin entry point ──────────────────────────────────────────────────────

class PromptYourselfPlugin extends Plugin {
  async onload() {
    await this.loadSettings();

    // Initialise WASM
    initSync({ module: wasmBytes });

    if (this.settings.apiKey) {
      setApiKey(this.settings.apiKey);
    }

    // Load system prompt from disk
    await this.loadSystemPrompt();

    this.registerView(VIEW_TYPE, (leaf) => new PromptYourselfView(leaf, this));

    this.addRibbonIcon('message-square', 'Prompt Yourself', () => {
      this.activateView();
    });

    this.addCommand({
      id: 'open-prompt-yourself',
      name: 'Open Prompt Yourself panel',
      callback: () => this.activateView(),
    });

    this.addSettingTab(new PromptYourselfSettingTab(this.app, this));
  }

  async activateView() {
    const { workspace } = this.app;
    let leaf = workspace.getLeavesOfType(VIEW_TYPE)[0];
    if (!leaf) {
      leaf = workspace.getRightLeaf(false);
      await leaf.setViewState({ type: VIEW_TYPE, active: true });
    }
    workspace.revealLeaf(leaf);
  }

  async loadSettings() {
    const data = await this.loadData();
    this.settings = Object.assign({}, DEFAULT_SETTINGS, data);
  }

  async saveSettings() {
    await this.saveData(this.settings);
  }

  async loadSystemPrompt() {
    const promptPath = this.settings.systemPromptPath;
    if (!promptPath) {
      console.log('[Prompt Yourself] No systemPromptPath configured - using compiled-in default');
      return;
    }
    try {
      const fs = require('fs');
      if (fs.existsSync(promptPath)) {
        const content = fs.readFileSync(promptPath, 'utf-8');
        setSystemPrompt(content);
        console.log('[Prompt Yourself] Loaded system prompt from', promptPath);
      } else {
        console.log('[Prompt Yourself] File not found:', promptPath, '- using compiled-in default');
      }
    } catch (err) {
      console.warn('[Prompt Yourself] Failed to load system prompt:', err.message);
    }
  }
}

module.exports = PromptYourselfPlugin;
