/*
 * Prompt Yourself – Obsidian Plugin
 *
 * Side panel chat that uses an OpenAI-compatible API to answer questions
 * about a vault folder.
 *
 * ── Architecture ─────────────────────────────────────────────────────────────
 *
 * Core logic is implemented in Rust and compiled to WASM. The Rust `Chat`
 * calls a JS callback (`setLoadEntriesCallback`) to load file entries.
 *
 * Secrets (API keys) are stored in the OS keychain via Obsidian's
 * SecretStorage API (v1.11.4+). Settings are organized into profiles,
 * each with its own folder path, test mode, and API credentials.
 *
 * ── Re-entrancy warning ──────────────────────────────────────────────────────
 *
 * The `loadEntries` callback MUST NOT call any WASM function that acquires
 * the chat lock (e.g. `chatCompletion`, `loadInitialContext`, `resetChat`),
 * or a "Re-entry detected" error will be thrown.
 */

import { Plugin, Notice } from 'obsidian';
import { initSync, setApiKey, setApiBase, getTimelineForDate } from './core_wasm.js';
import wasmBytes from './core_wasm_bg.wasm';
import { VIEW_TYPE, QUEST_VIEW_TYPE } from './lib/constants.js';
import { PromptYourselfQuestView } from './lib/quest-view.js';
import { PromptYourselfView } from './lib/chat-view.js';
import { PromptYourselfSettingTab, DEFAULT_SETTINGS } from './lib/settings.js';
import { KeychainService } from './lib/keychain.js';
import { ProfileManager } from './lib/profiles.js';
import { ObsidianQuestRepository } from './lib/quest-repository.js';
import { ObsidianTimelineRepository } from './lib/timeline-repository.js';
import { TimelineBlockComponent } from './lib/timeline-block.js';

// ─── Plugin entry point ──────────────────────────────────────────────────────

class PromptYourselfPlugin extends Plugin {
  async onload() {
    await this.loadSettings();

    // Initialise WASM
    initSync({ module: wasmBytes });

    // Set up keychain and profiles
    this.keychain = new KeychainService(this.app, this.settings);
    this.profiles = new ProfileManager(this, this.keychain);

    // Migrate from flat settings to profile model (one-time)
    await this.profiles.migrateFromFlat();
    await this.saveSettings();

    // Load the active profile's credentials into WASM
    this._applyActiveProfile();

    // Create repositories (persist via plugin data store)
    this.questRepository = new ObsidianQuestRepository(this);
    this.timelineRepository = new ObsidianTimelineRepository(this);

    // Load theme fonts
    this._themeFont = document.createElement('link');
    this._themeFont.rel = 'stylesheet';
    this._themeFont.href =
      'https://fonts.googleapis.com/css2?family=Cinzel:wght@400;600;700&family=Kalam:wght@400;700&display=swap';
    document.head.appendChild(this._themeFont);

    this.registerView(VIEW_TYPE, (leaf) => new PromptYourselfView(leaf, this));
    this.registerView(QUEST_VIEW_TYPE, (leaf) => new PromptYourselfQuestView(leaf));

    this.addRibbonIcon('message-square', 'Prompt Yourself', () => {
      this.activateView();
    });

    this.addCommand({
      id: 'open-prompt-yourself',
      name: 'Open Prompt Yourself panel',
      callback: () => this.activateView(),
    });

    this.registerTimelineBlockProcessor();

    this.addSettingTab(new PromptYourselfSettingTab(this.app, this));
  }

  /**
   * Push the active profile's credentials into WASM.
   */
  _applyActiveProfile() {
    const profile = this.profiles.activeProfile;
    if (!profile) return;

    const apiKey = this.profiles.getApiKey(profile.id);
    if (apiKey) setApiKey(apiKey);

    const apiBase = this.profiles.getApiBase(profile.id);
    if (apiBase) setApiBase(apiBase);

    this._secretsLoaded = true;

    // Notify user
    if (this.keychain.isAvailable && apiKey && !this._keychainNotified) {
      this._keychainNotified = true;
      new Notice(`🔐 Profile "${profile.name}" — key stored in system keychain`);
    }
  }

  registerTimelineBlockProcessor() {
    this.registerMarkdownCodeBlockProcessor('day-timeline', async (source, el, ctx) => {
      const dateMatch = source.match(/date:\s*(\d{4})-(\d{2})-(\d{2})/);
      if (!dateMatch) {
        el.createEl('p', { text: 'day-timeline: missing or invalid date', cls: 'quests-empty' });
        return;
      }

      const year = parseInt(dateMatch[1], 10);
      const month = parseInt(dateMatch[2], 10);
      const day = parseInt(dateMatch[3], 10);

      const child = new TimelineBlockComponent(el, year, month, day);
      ctx.addChild(child);
    });
  }

  onunload() {
    if (this._themeFont && this._themeFont.parentNode) {
      this._themeFont.parentNode.removeChild(this._themeFont);
    }
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
