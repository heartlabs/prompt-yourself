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

import { Plugin } from 'obsidian';
import { initSync, setApiKey, setApiBase, getTimelineForDate } from './core_wasm.js';
import wasmBytes from './core_wasm_bg.wasm';
import { VIEW_TYPE, QUEST_VIEW_TYPE } from './lib/constants.js';
import { PromptYourselfQuestView } from './lib/quest-view.js';
import { PromptYourselfView } from './lib/chat-view.js';
import { PromptYourselfSettingTab, DEFAULT_SETTINGS } from './lib/settings.js';
import { ObsidianQuestRepository } from './lib/quest-repository.js';
import { ObsidianTimelineRepository } from './lib/timeline-repository.js';
import { TimelineBlockComponent } from './lib/timeline-block.js';

// ─── Plugin entry point ──────────────────────────────────────────────────────

class PromptYourselfPlugin extends Plugin {
  async onload() {
    await this.loadSettings();

    // Initialise WASM
    initSync({ module: wasmBytes });

    // Create repositories (persist via plugin data store)
    this.questRepository = new ObsidianQuestRepository(this);
    this.timelineRepository = new ObsidianTimelineRepository(this);

    if (this.settings.apiKey) {
      setApiKey(this.settings.apiKey);
    }
    if (this.settings.apiBase) {
      setApiBase(this.settings.apiBase);
    }

    // Load theme fonts (Cinzel + Kalam for the Adventurer's Chronicle theme)
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

  registerTimelineBlockProcessor() {
    this.registerMarkdownCodeBlockProcessor('day-timeline', async (source, el, ctx) => {
      // Parse date from YAML source:  date: 2026-06-04
      const dateMatch = source.match(/date:\s*(\d{4})-(\d{2})-(\d{2})/);
      if (!dateMatch) {
        el.createEl('p', { text: 'day-timeline: missing or invalid date', cls: 'quests-empty' });
        return;
      }

      const year = parseInt(dateMatch[1], 10);
      const month = parseInt(dateMatch[2], 10);
      const day = parseInt(dateMatch[3], 10);

      // Create a child that auto-refreshes.
      // ctx.addChild calls child.onload() which triggers the initial render.
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
