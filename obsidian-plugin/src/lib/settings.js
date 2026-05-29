import { PluginSettingTab, Setting } from 'obsidian';
import { VIEW_TYPE } from './constants.js';
import { setApiKey } from '../core_wasm.js';

export const DEFAULT_SETTINGS = {
  apiKey: '',
  folderPath: '',
  systemPromptPath: '/Users/neidhartorlich/dev/prompt-yourself/core/resources/system-prompt.md',
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
  }
}
