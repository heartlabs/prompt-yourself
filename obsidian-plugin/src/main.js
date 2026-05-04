/*
 * Prompt Yourself – Obsidian Plugin
 *
 * Side panel chat that uses the DeepSeek API to answer questions about a vault folder
 * (produced as a YAML document with all text files).
 *
 * Core logic (YAML producer, API client) is implemented in Rust and compiled to WASM.
 * See ../core-wasm/ for the Rust source and ../../core/ for the domain logic.
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 * NOTE about WASM loading strategy
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * Currently this plugin BUNDLES the WASM module into a single main.js via esbuild.
 * If you want to switch to RUNTIME dynamic import instead (to avoid the build step):
 *
 *   async onload() {
 *     const wasm = await import('./core_wasm.js');
 *     // wasm is now auto-initialized, use wasm.produceYaml(), wasm.chatCompletion() etc.
 *   }
 *
 * Pros of dynamic import: no build step, lazy loading.
 * Cons: async init can be flaky across Obsidian versions, error handling is manual,
 * must ship two extra files (core_wasm.js + core_wasm_bg.wasm).
 *
 * The bundling approach (esbuild) was chosen for reliability and single-file distribution.
 * ═══════════════════════════════════════════════════════════════════════════════
 */

import { Plugin, ItemView, PluginSettingTab, Setting, Notice } from 'obsidian';
import { initSync, produceYaml, buildInitialMessages, setApiKey, setSystemPrompt, chatCompletion } from './core_wasm.js';
import wasmBytes from './core_wasm_bg.wasm';

// ─── Constants ───────────────────────────────────────────────────────────────

const TEXT_EXTENSIONS = new Set([
  '.md', '.txt', '.json', '.yaml', '.yml', '.toml', '.csv',
  '.html', '.css', '.scss', '.xml', '.log',
]);

const VIEW_TYPE = 'prompt-yourself-view';

// ─── View (side panel) ───────────────────────────────────────────────────────

class PromptYourselfView extends ItemView {
  constructor(leaf, plugin) {
    super(leaf);
    this.plugin = plugin;
    this.messages = [];
    this.abortController = null;
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

  async loadFolder() {
    const folderPath = this.plugin.settings.folderPath;
    if (folderPath === undefined) return;

    // Reset conversation
    this.messages = [];
    this.chatAreaEl.empty();
    this.updateFolderLabel();

    let folder;
    if (folderPath === '' || folderPath === '/') {
      // Whole vault
      folder = this.app.vault.getRoot();
    } else {
      folder = this.app.vault.getAbstractFileByPath(folderPath);
    }

    if (!folder || !folder.children) {
      this.addMessage('system', '⚠️ Folder not found: "' + folderPath + '". Check settings.');
      return;
    }

    const files = await this.collectFolderFiles(folder, folderPath);
    const filesJson = JSON.stringify(files);
    const yamlContent = produceYaml(filesJson);
    this.messages = JSON.parse(buildInitialMessages(yamlContent));
    this.addMessage('system', 'Loaded folder "' + (folderPath || '/') + '" (' + files.length + ' files). Ask away!');
  }

  async collectFolderFiles(folder, rootPath) {
    const results = [];
    const children = folder.children || [];

    // Normalise rootPath: strip leading/trailing slashes, empty string means whole vault
    const prefix = rootPath ? rootPath.replace(/^\/+|\/+$/g, '') : '';

    for (const child of children) {
      if (child.name.startsWith('.')) continue;
      if (child.name === 'node_modules') continue;

      if (child.children) {
        // Folder
        const sub = await this.collectFolderFiles(child, rootPath);
        results.push(...sub);
      } else {
        // File — compute relative path
        const childAbs = child.path.replace(/^\//, '');
        let relPath;
        if (!prefix) {
          relPath = childAbs; // whole vault
        } else if (childAbs === prefix) {
          relPath = '';
        } else if (childAbs.startsWith(prefix + '/')) {
          relPath = childAbs.slice(prefix.length + 1);
        } else {
          relPath = childAbs;
        }

        const dotIdx = child.name.lastIndexOf('.');
        const ext = dotIdx !== -1 ? child.name.slice(dotIdx).toLowerCase() : '';
        let content = null;
        if (TEXT_EXTENSIONS.has(ext)) {
          try {
            content = await this.app.vault.read(child);
          } catch (_) {
            content = null;
          }
        }
        results.push({ path: relPath, content });
      }
    }
    return results;
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
    this.messages.push({ role: 'user', content: text });

    this.inputEl.value = '';
    this.setLoading(true);

    if (this.abortController) {
      this.abortController.abort();
    }
    this.abortController = new AbortController();

    try {
      const messagesJson = JSON.stringify(this.messages);
      const reply = await chatCompletion(messagesJson, 1000);
      this.addMessage('assistant', reply);
      this.messages.push({ role: 'assistant', content: reply });
    } catch (err) {
      // AbortError is thrown by wasm-bindgen, check by name
      if (err.name === 'AbortError') return;
      this.addMessage('system', '❌ Error: ' + err.message);
    } finally {
      this.setLoading(false);
      this.abortController = null;
    }
  }

  addMessage(role, content) {
    const msgEl = this.chatAreaEl.createEl('div', {
      cls: 'message ' + role,
      text: content,
    });
    this.chatAreaEl.scrollTo(0, this.chatAreaEl.scrollHeight);
    return msgEl;
  }

  setLoading(loading) {
    this.inputEl.disabled = loading;
    this.sendBtn.disabled = loading;
    this.sendBtn.setText(loading ? '…' : 'Send');
  }

  async onClose() {
    if (this.abortController) {
      this.abortController.abort();
    }
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
            // Sync the API key to WASM immediately so the user doesn't
            // have to reload the plugin after changing the key.
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
        // Collect all folder paths from the vault
        const allFiles = this.app.vault.getAllLoadedFiles();
        const pathSet = new Set();
        for (const f of allFiles) {
          if (f.children) {
            // It's a TFolder — collect its path
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

          // Reload the panel if it's open
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

    // ── Initialise WASM ────────────────────────────────────────────────────
    // Pass {module: bytes} to avoid the deprecation warning about the
    // bare-Uint8Array argument form.
    initSync({ module: wasmBytes });

    // Pass the stored API key to the WASM module.
    // This sets a Rust OnceLock<String> inside the WASM instance's linear
    // memory, so it persists for the lifetime of the WASM module.
    if (this.settings.apiKey) {
      setApiKey(this.settings.apiKey);
    }

    // ── Load system prompt from disk ──────────────────────────────────────
    // The prompt file lives at workspace-root/core/resources/system-prompt.md.
    // We resolve it relative to the plugin directory (which is inside the
    // workspace's .obsidian/plugins/ folder).
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
    // Read the system prompt from a file on disk using Node's fs module.
    // The vault adapter is sandboxed to vault-relative paths, so for absolute
    // paths outside the vault we need fs directly.
    const promptPath = this.settings.systemPromptPath;

    if (!promptPath) {
      console.log('[Prompt Yourself] No systemPromptPath configured - using compiled-in default');
      return;
    }

    try {
      const fs = require('fs');
      const exists = fs.existsSync(promptPath);
      if (exists) {
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
