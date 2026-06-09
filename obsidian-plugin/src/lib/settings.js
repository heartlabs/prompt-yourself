import { PluginSettingTab, Setting } from 'obsidian';
import { VIEW_TYPE } from './constants.js';
import { setApiKey, setApiBase, setTestMode, clearGameData } from '../core_wasm.js';
import { KeychainService } from './keychain.js';
import { ProfileManager } from './profiles.js';

export const DEFAULT_SETTINGS = {
  apiKey: '',
  apiBase: 'https://api.deepseek.com',
  folderPath: '',
  testMode: false,
  profiles: [{ id: 'default', name: 'Default', folderPath: '', testMode: false }],
  activeProfileId: 'default',
};

export class PromptYourselfSettingTab extends PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display() {
    const { containerEl } = this;
    containerEl.empty();

    const keychain = new KeychainService(this.app, this.plugin.settings);
    const profileManager = new ProfileManager(this.plugin, keychain);
    const activeProfile = profileManager.activeProfile;

    new Setting(containerEl).setName('Prompt Yourself').setHeading();

    // ── Profile selector ──────────────────────────────────────────────

    const profileSetting = new Setting(containerEl)
      .setName('Active Profile')
      .setDesc('Switch between provider configurations.');

    const profileDropdown = profileSetting.addDropdown((dropdown) => {
      const profiles = profileManager.list();
      for (const p of profiles) {
        dropdown.addOption(p.id, p.name);
      }
      dropdown.setValue(activeProfile?.id || 'default');
      dropdown.onChange(async (value) => {
        // Switch to new profile (display() re-renders everything)
        const switched = profileManager.setActive(value);
        if (switched) {
          await this.plugin.saveSettings();
          // Re-init chat with new profile's credentials
          this._applyActiveProfile(profileManager, keychain);
          // Refresh UI
          this.display();
        }
      });
    });

    // Add button to create new profile
    profileSetting.addButton((button) =>
      button.setButtonText('+').onClick(async () => {
        const name = `Profile ${profileManager.list().length + 1}`;
        const profile = profileManager.create(name);
        profileManager.setActive(profile.id);
        await this.plugin.saveSettings();
        this.display();
      })
    );

    // Delete button (only if more than one profile)
    if (profileManager.list().length > 1 && activeProfile) {
      profileSetting.addButton((button) => {
        button.buttonEl.addClass('mod-warning');
        button.setButtonText('×').onClick(async () => {
          if (await profileManager.delete(activeProfile.id)) {
            await this.plugin.saveSettings();
            this.display();
          }
        });
      });
    }

    // Rename input
    if (activeProfile) {
      new Setting(containerEl)
        .setName('Profile Name')
        .addText((text) =>
          text.setPlaceholder('Profile name')
            .setValue(activeProfile.name)
            .onChange(async (value) => {
              profileManager.rename(activeProfile.id, value);
              await this.plugin.saveSettings();
              // Refresh dropdown label by re-rendering
              this.display();
            })
        );
    }

    // ── Separator: Profile-specific settings ─────────────────────────

    if (activeProfile) {
      new Setting(containerEl).setName(`Profile: ${activeProfile.name}`).setHeading();

      const useKeychain = keychain.isAvailable;

      // API Key
      new Setting(containerEl)
        .setName('API Key')
        .setDesc(useKeychain
          ? 'Stored in your system keychain.'
          : 'Your API key for this profile.')
        .addText((text) => {
          text.inputEl.type = 'password';
          text.inputEl.spellcheck = false;

          const saved = profileManager.getApiKey(activeProfile.id);
          if (saved) text.setValue(saved);

          if (!this.plugin._secretsLoaded) {
            this._applyActiveProfile(profileManager, keychain);
          }

          text.setPlaceholder('sk-...').onChange(async (value) => {
            const trimmed = value.trim();
            if (trimmed) {
              await profileManager.setApiKey(trimmed, activeProfile.id);
              // If this is the active profile, push to WASM immediately
              if (activeProfile.id === profileManager.activeProfileId) {
                setApiKey(trimmed);
              }
            }
            await this.plugin.saveSettings();
          });
        });

      if (useKeychain) {
        // Append keychain badge to the name column
        const infoEl = containerEl.querySelector('.setting-item-info:last-of-type');
        if (infoEl && !infoEl.querySelector('.keychain-badge')) {
          const badge = infoEl.createEl('span', { cls: 'keychain-badge' });
          badge.textContent = '🔐';
          badge.style.cssText = 'font-size: 0.75em; opacity: 0.6; margin-left: 8px;';
        }
      }

      // Provider URL
      new Setting(containerEl)
        .setName('Provider URL')
        .setDesc(
          'Base URL of an OpenAI-compatible API. ' +
          'Examples: https://api.deepseek.com, https://api.openai.com/v1, ' +
          'http://localhost:11434/v1 (Ollama), http://localhost:8000/v1 (vLLM)'
        )
        .addText((text) => {
          const saved = profileManager.getApiBase(activeProfile.id);
          if (saved) {
            text.setValue(saved);
          } else {
            text.setValue(activeProfile.folderPath ? '' : 'https://api.deepseek.com');
          }

          text.setPlaceholder('https://api.deepseek.com').onChange(async (value) => {
            const url = value.trim().replace(/\/+$/, '');
            const finalUrl = url || 'https://api.deepseek.com';
            await profileManager.setApiBase(finalUrl, activeProfile.id);
            if (activeProfile.id === profileManager.activeProfileId) {
              setApiBase(finalUrl);
            }
            await this.plugin.saveSettings();
          });
        });

      // Folder
      const folderSetting = new Setting(containerEl)
        .setName('Folder')
        .setDesc(
          'Choose which vault folder to use as context for this profile. ' +
          'All text files inside are bundled into a YAML document for the AI.'
        );

      folderSetting.addDropdown((dropdown) => {
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

        dropdown.setValue(activeProfile.folderPath);

        dropdown.onChange(async (value) => {
          profileManager.update(activeProfile.id, { folderPath: value });
          await this.plugin.saveSettings();

          // Refresh chat view if open
          const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE);
          if (leaves.length > 0) {
            const view = leaves[0].view;
            if (view && view.loadFolder) {
              await view.loadFolder();
            }
          }
        });
      });

      // Test Mode
      const testSetting = new Setting(containerEl)
        .setName('Testing Mode')
        .setDesc(
          'When enabled, the coaching personality is suspended. ' +
          'Use this to test game features (quests, timeline, etc.).'
        );

      testSetting.addToggle((toggle) => {
        toggle.setValue(activeProfile.testMode);
        toggle.onChange(async (value) => {
          profileManager.update(activeProfile.id, { testMode: value });
          await this.plugin.saveSettings();
          // Apply immediately if chat is initialized; otherwise it's applied
          // when the chat view calls initChat() and checks profile.testMode
          try { setTestMode(value); } catch (_) { /* chat not yet initialized */ }
        });
      });
    }

    // ── Data ───────────────────────────────────────────────────────────

    new Setting(containerEl).setName('Data').setHeading();

    new Setting(containerEl)
      .setName('Reset Game Data')
      .setDesc(
        'Clear all quests and timeline entries. Settings and profiles are preserved. ' +
        'Use this if you run into schema errors after an update.'
      )
      .addButton((button) =>
        button
          .setButtonText('Reset')
          .onClick(async () => {
            const data = await this.plugin.loadData();
            data.quests = [];
            data.timeline = [];
            await this.plugin.saveData(data);

            clearGameData();

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

  /**
   * Push the active profile's credentials to the WASM adapter.
   */
  _applyActiveProfile(profileManager, keychain) {
    const profile = profileManager.activeProfile;
    if (!profile) return;

    const apiKey = profileManager.getApiKey(profile.id);
    if (apiKey) setApiKey(apiKey);

    const apiBase = profileManager.getApiBase(profile.id);
    if (apiBase) setApiBase(apiBase);

    if (profile.testMode) {
      try { setTestMode(true); } catch (_) {}
    }

    this.plugin._secretsLoaded = true;
  }
}
