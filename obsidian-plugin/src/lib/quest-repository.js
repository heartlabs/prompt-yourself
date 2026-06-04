/**
 * Obsidian quest repository – persists quests via the plugin data store.
 *
 * Quest state is saved under the `quests` key in the plugin's data file.
 *
 * The Rust `WasmQuestRepository` calls these methods across the WASM boundary
 * via the callbacks registered with `setQuestRepositoryCallbacks`.
 */

export class ObsidianQuestRepository {
  /**
   * @param {import('obsidian').Plugin} plugin
   */
  constructor(plugin) {
    this.plugin = plugin;
  }

  /**
   * Load all quests from the plugin data store.
   * @returns {Promise<string>} JSON array of quests (empty array if none).
   */
  async loadQuests() {
    const data = await this.plugin.loadData();
    const quests = data.quests || [];
    // Filter out corrupt entries (must have title + status)
    const valid = quests.filter(q =>
      typeof q.title === 'string' &&
      ['Open', 'Completed', 'Pinned'].includes(q.status)
    );
    return JSON.stringify(valid);
  }

  /**
   * Save the full quest list to the plugin data store.
   * @param {string} json – JSON array of quest objects.
   * @returns {Promise<void>}
   */
  async saveQuests(json) {
    const data = await this.plugin.loadData();
    data.quests = JSON.parse(json);
    await this.plugin.saveData(data);
  }
}
