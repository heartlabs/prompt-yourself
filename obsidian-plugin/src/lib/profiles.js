/**
 * ProfileManager — multi-profile management for plugin settings.
 *
 * Each profile stores non-secret settings (folderPath, testMode) in data.json.
 * Secrets (apiKey, apiBase) are stored in the OS keychain via KeychainService,
 * scoped by profile ID.
 *
 * data.json structure:
 * {
 *   profiles: [
 *     { id: "default", name: "Default", folderPath: "", testMode: false },
 *     { id: "work", name: "Work", folderPath: "journal/", testMode: false }
 *   ],
 *   activeProfileId: "default",
 *   // ... other plugin settings
 * }
 *
 * Keychain keys:
 *   prompt-yourself-{profileId}-api-key
 *   prompt-yourself-{profileId}-api-base
 */

let _idCounter = 0;

/**
 * Generate a unique profile ID.
 */
function generateId() {
  return 'profile-' + (++_idCounter) + '-' + Date.now().toString(36);
}

export class ProfileManager {
  /**
   * @param {object} plugin - The PromptYourselfPlugin instance
   * @param {KeychainService} keychain - Shared keychain service
   */
  constructor(plugin, keychain) {
    this._plugin = plugin;
    this._keychain = keychain;
  }

  // ── Data access ────────────────────────────────────────────────────

  /** All profiles from the plugin's data store. */
  get profiles() {
    if (!this._plugin.settings.profiles) {
      // Migration: create default profile from flat settings
      this._plugin.settings.profiles = [
        { id: 'default', name: 'Default', folderPath: this._plugin.settings.folderPath || '', testMode: !!this._plugin.settings.testMode },
      ];
      this._plugin.settings.activeProfileId = 'default';
    }
    return this._plugin.settings.profiles;
  }

  set profiles(value) {
    this._plugin.settings.profiles = value;
  }

  /** The active profile object. */
  get activeProfile() {
    const id = this._plugin.settings.activeProfileId || 'default';
    return this.profiles.find(p => p.id === id) || this.profiles[0] || null;
  }

  /** The active profile ID. */
  get activeProfileId() {
    return this.activeProfile?.id || 'default';
  }

  // ── CRUD ───────────────────────────────────────────────────────────

  /**
   * List all profiles.
   * @returns {Array<{id: string, name: string, folderPath: string, testMode: boolean}>}
   */
  list() {
    return [...this.profiles];
  }

  /**
   * Get a profile by ID.
   * @param {string} id
   * @returns {object|null}
   */
  get(id) {
    return this.profiles.find(p => p.id === id) || null;
  }

  /**
   * Create a new profile with defaults.
   * @param {string} name - Display name
   * @returns {object} The new profile
   */
  create(name) {
    const profile = {
      id: generateId(),
      name: name.trim() || 'New Profile',
      folderPath: '',
      testMode: false,
    };
    this.profiles = [...this.profiles, profile];
    return profile;
  }

  /**
   * Delete a profile and its keychain secrets.
   * Cannot delete the last profile.
   * @param {string} id
   * @returns {boolean} True if deleted
   */
  async delete(id) {
    const list = this.profiles;
    if (list.length <= 1) return false;
    const idx = list.findIndex(p => p.id === id);
    if (idx === -1) return false;

    // Clean up keychain secrets
    await this._keychain.deleteSecret('api-key', id);
    await this._keychain.deleteSecret('api-base', id);

    // Remove profile
    list.splice(idx, 1);
    this.profiles = list;

    // If the deleted profile was active, switch to the first remaining
    if (this._plugin.settings.activeProfileId === id) {
      this._plugin.settings.activeProfileId = list[0].id;
    }
    return true;
  }

  /**
   * Rename a profile.
   * @param {string} id
   * @param {string} name
   */
  rename(id, name) {
    const profile = this.get(id);
    if (!profile) return;
    profile.name = name.trim() || profile.name;
  }

  /**
   * Update a profile's non-secret fields.
   * @param {string} id
   * @param {object} changes - { folderPath?, testMode? }
   */
  update(id, changes) {
    const profile = this.get(id);
    if (!profile) return;
    if (changes.folderPath !== undefined) profile.folderPath = changes.folderPath;
    if (changes.testMode !== undefined) profile.testMode = changes.testMode;
  }

  /**
   * Set the active profile.
   * @param {string} id
   * @returns {object|null} The newly active profile, or null if not found
   */
  setActive(id) {
    const profile = this.get(id);
    if (!profile) return null;
    this._plugin.settings.activeProfileId = id;
    return profile;
  }

  // ── Credential helpers (delegate to KeychainService) ───────────────

  /**
   * Get the API key for a profile (or active profile).
   * @param {string} [profileId]
   * @returns {string|null}
   */
  getApiKey(profileId) {
    return this._keychain.getSecret('api-key', profileId || this.activeProfileId);
  }

  /**
   * Set the API key for a profile (or active profile).
   * @param {string} value
   * @param {string} [profileId]
   */
  async setApiKey(value, profileId) {
    await this._keychain.setSecret('api-key', value, profileId || this.activeProfileId);
  }

  /**
   * Get the API base URL for a profile (or active profile).
   * @param {string} [profileId]
   * @returns {string|null}
   */
  getApiBase(profileId) {
    return this._keychain.getSecret('api-base', profileId || this.activeProfileId);
  }

  /**
   * Set the API base URL for a profile (or active profile).
   * @param {string} value
   * @param {string} [profileId]
   */
  async setApiBase(value, profileId) {
    await this._keychain.setSecret('api-base', value, profileId || this.activeProfileId);
  }

  // ── Migration from flat settings ───────────────────────────────────

  /**
   * Migrate from flat settings (pre-profile) to profile model.
   * Creates a "Default" profile if none exist.
   * Migrates apiKey/apiBase from flat fallback into keychain.
   * Should be called once on plugin load.
   */
  async migrateFromFlat() {
    const hasProfiles = Array.isArray(this._plugin.settings.profiles)
      && this._plugin.settings.profiles.length > 0;

    if (!hasProfiles) {
      // Create default profile from existing flat settings
      this._plugin.settings.profiles = [{
        id: 'default',
        name: 'Default',
        folderPath: this._plugin.settings.folderPath || '',
        testMode: !!this._plugin.settings.testMode,
      }];
      this._plugin.settings.activeProfileId = 'default';
    }

    // Migrate keychain secrets from flat keys to profile-scoped keys
    if (this._keychain.isAvailable) {
      const flatApiKey = this._keychain.getSecret('api-key'); // old unscoped key
      const flatApiBase = this._keychain.getSecret('api-base'); // old unscoped key

      if (flatApiKey) {
        // Check if already migrated to profile scope
        const scoped = this._keychain.getSecret('api-key', 'default');
        if (!scoped) {
          await this._keychain.setSecret('api-key', flatApiKey, 'default');
        }
        // Clean up flat key
        await this._keychain.deleteSecret('api-key');
      }

      if (flatApiBase) {
        const scoped = this._keychain.getSecret('api-base', 'default');
        if (!scoped) {
          await this._keychain.setSecret('api-base', flatApiBase, 'default');
        }
        await this._keychain.deleteSecret('api-base');
      }
    }

    // Also handle the case where keys are still in data.json settings
    if (this._plugin.settings.apiKey && this._keychain.isAvailable) {
      await this._keychain.setSecret('api-key', this._plugin.settings.apiKey, 'default');
      delete this._plugin.settings.apiKey;
    }
    if (this._plugin.settings.apiBase) {
      // Strip from data.json — keep in keychain or profile list
      delete this._plugin.settings.apiBase;
    }
    delete this._plugin.settings.folderPath;
    delete this._plugin.settings.testMode;
  }
}
