import { ItemView, MarkdownRenderer } from 'obsidian';
import { VIEW_TYPE, QUEST_VIEW_TYPE, CHAT_MODEL } from './constants.js';
import { buildVaultLoadCallback } from './journal-adapter.js';
import { setLoadEntriesCallback, initChat, loadInitialContext, chatCompletion } from '../core_wasm.js';

export class PromptYourselfView extends ItemView {
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

    // Quests button (opens a split pane)
    this.questsBtnEl = container.createEl('button', {
      cls: 'quests-btn',
      text: '🏆 Quests',
    });
    this.questsBtnEl.addEventListener('click', async () => {
      const leaf = this.app.workspace.getLeaf(true);
      await leaf.setViewState({ type: QUEST_VIEW_TYPE, active: true });
    });

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

    // Reset the chat panel UI
    this.chatAreaEl.empty();

    this.updateFolderLabel();

    // Register the loadEntries callback BEFORE initChat or any WASM calls
    const callback = buildVaultLoadCallback(folderPath, this.app.vault);
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
    if (this.isLoading) return;
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
      // Refresh any open Quest views so they update automatically
      const questLeaves = this.app.workspace.getLeavesOfType(QUEST_VIEW_TYPE);
      for (const leaf of questLeaves) {
        if (leaf.view && typeof leaf.view.render === 'function') {
          leaf.view.render();
        }
      }
    }
  }

  addMessage(role, content) {
    const msgEl = this.chatAreaEl.createEl('div', {
      cls: 'message ' + role,
    });

    if (role === 'assistant' || role === 'user' || role === 'tool') {
      MarkdownRenderer.render(this.app, content, msgEl, '/', this);
    } else {
      msgEl.setText(content);
    }

    this.chatAreaEl.scrollTo(0, this.chatAreaEl.scrollHeight);
    return msgEl;
  }

  setLoading(loading) {
    this.isLoading = loading;
    this.sendBtn.disabled = loading;
    this.sendBtn.setText(loading ? '…' : 'Send');

    if (loading) {
      // Create the typing indicator fresh, appended after the last message
      this.typingIndicatorEl = this.chatAreaEl.createEl('div', { cls: 'typing-indicator' });
      this.typingIndicatorEl.createEl('span');
      this.typingIndicatorEl.createEl('span');
      this.typingIndicatorEl.createEl('span');
      this.chatAreaEl.scrollTo(0, this.chatAreaEl.scrollHeight);
    } else {
      // Remove the indicator from the DOM
      if (this.typingIndicatorEl) {
        this.typingIndicatorEl.detach();
        this.typingIndicatorEl = null;
      }
    }
  }

  async onClose() {
    // no-op
  }
}
