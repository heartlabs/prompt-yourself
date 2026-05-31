/**
 * Obsidian vault adapter for the core's `JournalPort`.
 *
 * Builds the JS callback that the Rust core's `WasmJournalAdapter` calls via
 * `JournalPort::load_entries`. The callback walks the Obsidian vault, filters
 * files by mtime, and returns a JSON array of `{path, content, lastModified}`
 * objects — exactly the shape that `WasmJournalAdapter` deserializes into
 * `Vec<FileEntry>`.
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 * Re-entrancy warning
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * This callback MUST NOT call any WASM function that acquires the chat lock
 * (e.g. chatCompletion, loadInitialContext), or a "Re-entry detected" error
 * will be thrown. This is a pure data-fetching function — it reads the vault,
 * filters by mtime, and returns a JSON string. No WASM calls.
 */

import { TEXT_EXTENSIONS } from './constants.js';
import { msToIso8601 } from './helpers.js';

/**
 * Build a `loadEntries` callback for the Obsidian vault.
 *
 * The returned function receives a millisecond timestamp (Unix epoch) and must
 * return a Promise<string> — a JSON array of `{path, content, lastModified}`
 * objects for every file whose mtime is strictly after `sinceMs`.
 * `lastModified` must be an ISO 8601 string so chrono can deserialize it.
 *
 * @param {string} folderPath - The vault folder path to scan ('' means whole vault).
 * @param {import('obsidian').Vault} vault - The Obsidian vault instance.
 * @returns {(sinceMs: number | null) => Promise<string>}
 */
export function buildVaultLoadCallback(folderPath, vault) {
  return async (sinceMs) => {
    let folder;
    if (folderPath === '' || folderPath === '/') {
      folder = vault.getRoot();
    } else {
      folder = vault.getAbstractFileByPath(folderPath);
    }

    if (!folder || !folder.children) return '[]';

    const results = [];

    // Normalise rootPath
    const prefix = folderPath ? folderPath.replace(/^\/+|\/+$/g, '') : '';

    const walk = async (children) => {
      for (const child of children) {
        if (child.name.startsWith('.')) continue;
        if (child.name === 'node_modules') continue;

        if (child.children) {
          await walk(child.children);
        } else {
          // Relative path
          const childAbs = child.path.replace(/^\//, '');
          let relPath;
          if (!prefix) {
            relPath = childAbs;
          } else if (childAbs === prefix) {
            relPath = '';
          } else if (childAbs.startsWith(prefix + '/')) {
            relPath = childAbs.slice(prefix.length + 1);
          } else {
            relPath = childAbs;
          }

          // mtime filter
          const mtimeMs = child.stat && child.stat.mtime;
          if (sinceMs !== null && mtimeMs !== null && mtimeMs <= sinceMs) {
            continue;
          }

          // Content
          const dotIdx = child.name.lastIndexOf('.');
          const ext = dotIdx !== -1 ? child.name.slice(dotIdx).toLowerCase() : '';
          let content = null;
          if (TEXT_EXTENSIONS.has(ext)) {
            try {
              content = await vault.read(child);
              content = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
            } catch (_) {
              content = null;
            }
          }

          const lastModified = mtimeMs != null ? msToIso8601(mtimeMs) : null;
          results.push({ path: relPath, content, lastModified });
        }
      }
    };

    await walk(folder.children);

    if (results.length > 0) {
      console.log(
        `[prompt-yourself] loadEntries(sinceMs=${sinceMs}) returned ${results.length} file(s):`,
        results.map(r => `${r.path} (${r.lastModified ?? '?'})`).join(', ')
      );
    }

    return JSON.stringify(results);
  };
}
