/**
 * Obsidian quest repository – persists quests via the plugin data store.
 *
 * Quest state is saved under the `quests` key in the plugin's data file
 * (the same mechanism used for settings).
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
    let quests = data.quests || [];
    // Discard corrupt entries (e.g. old format with `completed` boolean)
    quests = quests.filter(q =>
      typeof q.title === 'string' &&
      ('completed_at' in q ?
        (q.completed_at === null || typeof q.completed_at === 'string') :
        false
      )
    );
    return JSON.stringify(quests);
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
