/*
 * Prompt Yourself – Obsidian Plugin
 * Side panel chat that uses the DeepSeek API to answer questions about a vault folder
 * (produced as a YAML document with all text files).
 */

const { Plugin, ItemView, PluginSettingTab, Setting, Notice } = require('obsidian');

// ─── Shared: YAML producer ──────────────────────────────────────────────────

function produceYaml(files, indent) {
  indent = indent || 2;
  if (!files || files.length === 0) {
    return '# (no files)\n';
  }
  const lines = [];
  for (const file of files) {
    lines.push('- path: ' + yamlQuote(file.path));
    if (file.content === null) {
      lines.push(sp(indent) + 'content: null');
    } else {
      lines.push(sp(indent) + 'content: |');
      const body = typeof file.content === 'string' ? file.content : String(file.content);
      const bodyLines = body.split('\n');
      if (bodyLines.length === 0 || (bodyLines.length === 1 && bodyLines[0] === '')) {
        lines.push(sp(indent * 2) + '""');
      } else {
        for (const line of bodyLines) {
          lines.push(sp(indent * 2) + line);
        }
      }
    }
  }
  return lines.join('\n') + '\n';
}

function yamlQuote(value) {
  if (typeof value !== 'string') return String(value);
  if (/^[a-zA-Z0-9_./\u{80}-\u{10FFFF} -]+$/u.test(value)) {
    return value;
  }
  const escaped = value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  return '"' + escaped + '"';
}

function sp(count) {
  let s = '';
  for (let i = 0; i < count; i++) s += ' ';
  return s;
}

// ─── Shared: API client ─────────────────────────────────────────────────────

async function chatCompletion({ apiKey, messages, signal, maxTokens }) {
  maxTokens = maxTokens || 1000;
  const response = await fetch('https://api.deepseek.com/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer ' + apiKey,
    },
    body: JSON.stringify({
      model: 'deepseek-chat',
      messages: messages,
      max_tokens: maxTokens,
    }),
    signal: signal,
  });
  if (!response.ok) {
    const errBody = await response.text().catch(() => '');
    throw new Error('DeepSeek API error (' + response.status + '): ' + errBody);
  }
  const data = await response.json();
  return data.choices[0].message.content;
}

function buildInitialMessages(documentContent) {
  return [
    { role: 'system', content: SYSTEM_PROMPT },
    {
      role: 'user',
      content: 'Here is the document to reference:\n\n' + documentContent,
    },
  ];
}

// ─── Constants ───────────────────────────────────────────────────────────────

const SYSTEM_PROMPT =
  'You are a helpful assistant that answers questions about a provided document.';

const TEXT_EXTENSIONS = new Set([
  '.md', '.txt', '.json', '.yaml', '.yml', '.toml', '.csv',
  '.js', '.ts', '.jsx', '.tsx', '.py', '.rb', '.go', '.rs',
  '.html', '.css', '.scss', '.xml', '.svg', '.env',
  '.cfg', '.ini', '.conf', '.log',
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
    if (!folderPath && folderPath !== '') return;

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
    const yamlContent = produceYaml(files);
    this.messages = buildInitialMessages(yamlContent);
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
      const reply = await chatCompletion({
        apiKey,
        messages: this.messages,
        signal: this.abortController.signal,
        maxTokens: 1000,
      });
      this.addMessage('assistant', reply);
      this.messages.push({ role: 'assistant', content: reply });
    } catch (err) {
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
}

module.exports = PromptYourselfPlugin;
