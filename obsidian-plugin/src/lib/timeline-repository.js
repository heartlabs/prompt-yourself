/**
 * Obsidian timeline repository – persists timeline entries via the plugin data store.
 *
 * Timeline state is saved under the `timeline` key in the plugin's data file.
 *
 * The Rust `WasmTimelineRepository` calls these methods across the WASM boundary
 * via the callbacks registered with `setTimelineRepositoryCallbacks`.
 */

export class ObsidianTimelineRepository {
  /**
   * @param {import('obsidian').Plugin} plugin
   */
  constructor(plugin) {
    this.plugin = plugin;
  }

  /**
   * Load all timeline entries from the plugin data store.
   * @returns {Promise<string>} JSON array of timeline entries.
   */
  async loadTimeline() {
    const data = await this.plugin.loadData();
    const entries = data.timeline || [];
    return JSON.stringify(entries);
  }

  /**
   * Save the full timeline entry list to the plugin data store.
   * @param {string} json – JSON array of timeline entry objects.
   * @returns {Promise<void>}
   */
  async saveTimeline(json) {
    const data = await this.plugin.loadData();
    data.timeline = JSON.parse(json);
    await this.plugin.saveData(data);
  }
}
