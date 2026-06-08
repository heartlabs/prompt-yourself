/**
 * KeychainService — secure credential storage via Obsidian's SecretStorage API.
 *
 * Wraps `app.secretStorage` (available since Obsidian v1.11.4) with a graceful
 * fallback to a plaintext settings object for older versions or environments
 * without a system keyring.
 *
 * Supports profile-scoped keys: pass `profileId` to scope secrets per profile.
 *
 * Usage:
 *   const keychain = new KeychainService(app, settings);
 *   await keychain.setSecret('api-key', 'sk-...', 'default');
 *   const key = await keychain.getSecret('api-key', 'default');
 */

const KEY_PREFIX = 'prompt-yourself';

export class KeychainService {
  /**
   * @param {object} app - Obsidian App instance
   * @param {object} fallback - Plain settings object to use when SecretStorage is unavailable
   */
  constructor(app, fallback) {
    this._fallback = fallback;
    this._secretStorage = app.secretStorage ?? null;
  }

  /** True if the OS keychain is available on this device. */
  get isAvailable() {
    return this._secretStorage !== null;
  }

  /**
   * Build the namespaced keychain key.
   * @param {string} id - Short identifier (e.g. 'api-key', 'api-base')
   * @param {string} [profileId] - Optional profile ID for multi-profile scoping
   * @returns {string}
   */
  _makeKey(id, profileId) {
    return profileId
      ? `${KEY_PREFIX}-${profileId}-${id}`
      : `${KEY_PREFIX}-${id}`;
  }

  /**
   * Store a secret. Prefers keychain, falls back to the settings object.
   * @param {string} id - Short identifier
   * @param {string} value - The secret value
   * @param {string} [profileId] - Optional profile ID
   */
  async setSecret(id, value, profileId) {
    const key = this._makeKey(id, profileId);
    if (this._secretStorage) {
      try {
        this._secretStorage.setSecret(key, value);
        // Strip from flat fallback if this is the default/unscoped key
        if (!profileId) {
          delete this._fallback[id === 'api-key' ? 'apiKey' : 'apiBase'];
        }
        return;
      } catch (e) {
        console.warn(`[Keychain] SecretStorage setSecret failed for "${key}", falling back to settings:`, e);
      }
    }
    // Fallback: store in plain settings object
    if (!profileId) {
      if (id === 'api-key') this._fallback.apiKey = value;
      else if (id === 'api-base') this._fallback.apiBase = value;
    }
  }

  /**
   * Retrieve a secret. Prefers keychain, falls back to settings object.
   * @param {string} id - Short identifier
   * @param {string} [profileId] - Optional profile ID
   * @returns {string|null} The secret value, or null if not found
   */
  getSecret(id, profileId) {
    const key = this._makeKey(id, profileId);
    if (this._secretStorage) {
      try {
        const value = this._secretStorage.getSecret(key);
        if (value !== null && value !== undefined) {
          return value;
        }
      } catch (e) {
        console.warn(`[Keychain] SecretStorage getSecret failed for "${key}", trying fallback:`, e);
      }
    }
    // Fallback: read from flat settings (only for unscoped keys)
    if (!profileId) {
      if (id === 'api-key') return this._fallback.apiKey || null;
      if (id === 'api-base') return this._fallback.apiBase || null;
    }
    return null;
  }

  /**
   * Delete a secret from both keychain and fallback.
   * @param {string} id - Short identifier
   * @param {string} [profileId] - Optional profile ID
   */
  async deleteSecret(id, profileId) {
    const key = this._makeKey(id, profileId);
    if (this._secretStorage) {
      try {
        if (typeof this._secretStorage.deleteSecret === 'function') {
          this._secretStorage.deleteSecret(key);
        }
      } catch (e) {
        console.warn(`[Keychain] SecretStorage deleteSecret failed for "${key}":`, e);
      }
    }
    // Also clear from flat fallback for unscoped keys
    if (!profileId) {
      if (id === 'api-key') delete this._fallback.apiKey;
      if (id === 'api-base') delete this._fallback.apiBase;
    }
  }

  /**
   * Migrate a secret from the flat fallback into the keychain.
   * @param {string} id - Short identifier
   * @returns {boolean} True if migration happened
   */
  async migrateFromFallback(id) {
    const current = id === 'api-key' ? this._fallback.apiKey : this._fallback.apiBase;
    if (!current) return false;
    if (!this._secretStorage) return false;

    const key = this._makeKey(id);
    try {
      const existing = this._secretStorage.getSecret(key);
      if (existing) return false;

      this._secretStorage.setSecret(key, current);
      if (id === 'api-key') delete this._fallback.apiKey;
      if (id === 'api-base') delete this._fallback.apiBase;
      return true;
    } catch (e) {
      console.warn(`[Keychain] Migration failed for "${id}":`, e);
      return false;
    }
  }
}
