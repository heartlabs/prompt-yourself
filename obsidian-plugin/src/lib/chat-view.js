import { ItemView, MarkdownRenderer } from 'obsidian';
import { VIEW_TYPE, QUEST_VIEW_TYPE, CHAT_MODEL } from './constants.js';
import { buildVaultLoadCallback } from './journal-adapter.js';
import { setLoadEntriesCallback, setQuestRepositoryCallbacks, setTimelineRepositoryCallbacks, initChat, loadInitialContext, chatCompletion, setTestMode, getTokenUsage } from '../core_wasm.js';

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

  /** Shorthand for the active profile. */
  get _profile() {
    return this.plugin.profiles?.activeProfile || null;
  }

  async onOpen() {
    const container = this.containerEl.children[1];
    container.empty();
    container.addClass('prompt-yourself-container');

    // Profile + folder label
    this.folderLabelEl = container.createEl('div', { cls: 'file-label' });
    this.updateFolderLabel();

    // Token usage indicator (top-right circle)
    this.tokenIndicatorEl = container.createEl('div', { cls: 'token-indicator' });
    this.tokenIndicatorEl.setAttribute('data-tooltip', 'No usage data yet');

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
    const profile = this._profile;
    if (!profile) {
      this.folderLabelEl.setText('📁 (set up a profile in settings)');
      return;
    }
    const name = profile.name;
    const path = profile.folderPath;
    if (!path) {
      this.folderLabelEl.setText(`👤 ${name} · 📁 Whole vault`);
    } else {
      this.folderLabelEl.setText(`👤 ${name} · 📁 ${path}`);
    }
  }

  async loadFolder() {
    const profile = this._profile;
    if (!profile) return;

    const folderPath = profile.folderPath;

    // Reset the chat panel UI
    this.chatAreaEl.empty();

    this.updateFolderLabel();

    // Register the loadEntries callback BEFORE initChat or any WASM calls
    const callback = buildVaultLoadCallback(folderPath, this.app.vault);
    setLoadEntriesCallback(callback);

    // Register the quest repository callbacks BEFORE initChat
    const questRepo = this.plugin.questRepository;
    if (questRepo) {
      setQuestRepositoryCallbacks({
        loadQuests: () => questRepo.loadQuests(),
        saveQuests: (json) => questRepo.saveQuests(json),
      });
    }

    // Register the timeline repository callbacks BEFORE initChat
    const timelineRepo = this.plugin.timelineRepository;
    if (timelineRepo) {
      setTimelineRepositoryCallbacks({
        loadTimeline: () => timelineRepo.loadTimeline(),
        saveTimeline: (json) => timelineRepo.saveTimeline(json),
      });
    }

    const apiKey = this.plugin.profiles.getApiKey(profile.id);
    if (apiKey) {
      try {
        // Initialise the Rust-side Chat (system prompt + API config).
        initChat(CHAT_MODEL);

        // Re-apply test mode if it was saved (initChat resets the prompt)
        if (profile.testMode) {
          setTestMode(true);
        }

        // Load every file (since epoch) — the callback handles the vault scan.
        const fileCount = await loadInitialContext();

        this.addMessage('system', `Loaded profile "${profile.name}" · folder "${folderPath || '/'}" (${fileCount} files). Ask away!`);
      } catch (e) {
        this.addMessage('system', '⚠️ Failed to initialise chat: ' + e.message);
      }
    } else {
      this.addMessage('system', '⚠️ Please set an API key for this profile in Plugin Settings.');
    }
  }

  async handleSend() {
    if (this.isLoading) return;
    const text = this.inputEl.value.trim();
    if (!text) return;

    const profile = this._profile;
    if (!profile) {
      this.addMessage('system', '⚠️ Set up a profile in Plugin Settings first.');
      return;
    }

    const apiKey = this.plugin.profiles.getApiKey(profile.id);
    if (!apiKey) {
      this.addMessage('system', '⚠️ Please set an API key for this profile in Plugin Settings.');
      return;
    }

    if (profile.folderPath === undefined) {
      this.addMessage('system', '⚠️ Select a folder in Plugin Settings first.');
      return;
    }

    this.addMessage('user', text);
    this.inputEl.value = '';
    this.setLoading(true);

    try {
      const json = await chatCompletion(text, Date.now());
      const messages = JSON.parse(json);
      for (const msg of messages) {
        if (msg.role === 'assistant' && msg.content) {
          this.addMessage('assistant', msg.content);
        } else if (msg.role === 'tool') {
          this.addMessage('tool', msg.content);
        }
      }

      // Update token usage indicator after each turn
      try {
        const usageJson = getTokenUsage();
        if (usageJson) {
          const usage = JSON.parse(usageJson);
          this.updateTokenIndicator(usage);
        }
      } catch (_) {
        // Silently ignore — token tracking is non-critical
      }
    } catch (err) {
      this.addMessage('system', '❌ Error: ' + err.message);
    } finally {
      this.setLoading(false);
      // Refresh any open Quest views so they update automatically
      const questLeaves = this.app.workspace.getLeavesOfType(QUEST_VIEW_TYPE);
      for (const leaf of questLeaves) {
        if (leaf.view && typeof leaf.view.render === 'function') {
          await leaf.view.render();
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

  /// Update the token usage indicator with data from the Rust core.
  updateTokenIndicator(usage) {
    if (!this.tokenIndicatorEl) return;

    const contextWindow = 1_000_000;
    const ctx = usage.context_tokens || 0;
    const pct = Math.min(100, (ctx / contextWindow) * 100);

    this.tokenIndicatorEl.style.setProperty('--fill-pct', pct.toFixed(1));

    // Abbreviate numbers: 1234 → 1.2K, 1_200_000 → 1.2M
    const abbrev = (n) => {
      if (n >= 1_000_000) return (n / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
      if (n >= 1_000) return (n / 1_000).toFixed(1).replace(/\.0$/, '') + 'K';
      return String(n);
    };

    this.tokenIndicatorEl.setAttribute('data-tooltip',
      `${abbrev(ctx)} / 1M (${pct.toFixed(0)}%)\n` +
      `${abbrev(usage.total_input_tokens)} input\n` +
      `${abbrev(usage.total_output_tokens)} output\n` +
      `${abbrev(usage.total_cached_tokens)} cached`
    );
  }

  async onClose() {
    // no-op
  }
}
