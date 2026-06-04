import { PluginSettingTab, Setting } from 'obsidian';
import { VIEW_TYPE } from './constants.js';
import { setApiKey, setTestMode, clearGameData } from '../core_wasm.js';

export const DEFAULT_SETTINGS = {
  apiKey: '',
  folderPath: '',
  testMode: false,
};

export class PromptYourselfSettingTab extends PluginSettingTab {
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

    containerEl.createEl('h3', { text: 'Testing' });

    new Setting(containerEl)
      .setName('Testing Mode')
      .setDesc(
        'When enabled, the coaching personality is suspended and the AI will ' +
        'obey your commands without pushback. Use this to test game features ' +
        '(quests, timeline, etc.). Revert to normal mode afterwards.'
      )
      .addToggle((toggle) =>
        toggle
          .setValue(this.plugin.settings.testMode)
          .onChange(async (value) => {
            this.plugin.settings.testMode = value;
            await this.plugin.saveSettings();
            try {
              setTestMode(value);
            } catch (e) {
              console.error('Failed to toggle test mode:', e);
            }
          })
      );

    containerEl.createEl('h3', { text: 'Data' });

    new Setting(containerEl)
      .setName('Reset Game Data')
      .setDesc(
        'Clear all quests and timeline entries. Settings are preserved. ' +
        'Use this if you run into schema errors after an update.'
      )
      .addButton((button) =>
        button
          .setButtonText('Reset')
          .onClick(async () => {
            // Clear persisted data
            const data = await this.plugin.loadData();
            data.quests = [];
            data.timeline = [];
            await this.plugin.saveData(data);

            // Clear WASM in-memory caches so next getGameState() reloads fresh
            clearGameData();

            // Refresh both the quest view and the chat view if open
            for (const viewType of ['prompt-yourself-view', 'prompt-yourself-quest-view']) {
              const leaves = this.app.workspace.getLeavesOfType(viewType);
              for (const leaf of leaves) {
                const view = leaf.view;
                if (view && view.render) {
                  await view.render();
                }
              }
            }
          })
      );
  }
}
