import { ItemView } from 'obsidian';
import { QUEST_VIEW_TYPE } from './constants.js';
import { getGameState } from '../core_wasm.js';

/**
 * Format an RFC3339 timestamp string to hh:mm:ss (local time).
 * Returns '--:--:--' if the timestamp is missing or unparseable.
 */
function formatTimestamp(rfc3339) {
  if (!rfc3339) return '--:--:--';
  try {
    const d = new Date(rfc3339);
    if (isNaN(d.getTime())) return '--:--:--';
    return d.toLocaleTimeString('en-GB', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    });
  } catch {
    return '--:--:--';
  }
}

export class PromptYourselfQuestView extends ItemView {
  constructor(leaf) {
    super(leaf);
  }

  getViewType() {
    return QUEST_VIEW_TYPE;
  }

  getDisplayText() {
    return 'Quests';
  }

  getIcon() {
    return 'trophy';
  }

  async onOpen() {
    await this.render();
  }

  async render() {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.addClass('prompt-yourself-quests');

    let state;
    try {
      const json = await getGameState();
      state = JSON.parse(json);
    } catch (e) {
      contentEl.createEl('p', { text: '⏳ Loading quests…' });
      setTimeout(() => this.render(), 500);
      return;
    }

    // ── Header ──────────────────────────────────────────────────────────────
    contentEl.createEl('h2', { text: '🏆 Quests' });

    // ── Open quests ─────────────────────────────────────────────────────────
    const open = state.openQuests || [];
    if (open.length > 0) {
      contentEl.createEl('h3', { text: 'Open (' + open.length + ')' });
      const openList = contentEl.createEl('ul');
      for (const q of open) {
        const li = openList.createEl('li');
        li.createEl('strong', { text: q.title });
        li.appendText(' — ' + q.description + ' (' + q.points + ' pts)');
      }
    } else {
      contentEl.createEl('p', { text: 'No open quests.', cls: 'quests-empty' });
    }

    // ── Pinned quests ───────────────────────────────────────────────────────
    const pinned = state.pinnedQuests || [];
    if (pinned.length > 0) {
      contentEl.createEl('h3', { text: '📌 Pinned (' + pinned.length + ')' });
      const pinnedList = contentEl.createEl('ul');
      for (const q of pinned) {
        const li = pinnedList.createEl('li', { cls: 'quests-pinned' });
        li.createEl('strong', { text: q.title });
        li.appendText(' — ' + q.description + ' (' + q.points + ' pts)');
      }
    }

    // ── Timeline ────────────────────────────────────────────────────────────
    const timeline = state.timeline || [];
    if (timeline.length > 0) {
      contentEl.createEl('h3', {
        text: '📜 Timeline (' + timeline.length + ')',
      });

      const timelineList = contentEl.createEl('ul', {
        cls: 'quests-timeline',
      });

      for (const entry of timeline) {
        const li = timelineList.createEl('li', { cls: 'quests-timeline-entry' });

        // ── Collapsed row (3 columns) ─────────────────────────────────────
        const row = li.createEl('div', { cls: 'quests-timeline-row' });

        // Column 1: Timestamp
        const timeCol = row.createEl('span', { cls: 'quests-timeline-time' });
        timeCol.setText(formatTimestamp(entry.occurredOn));

        // Column 2: Quest title
        const titleCol = row.createEl('span', { cls: 'quests-timeline-title' });
        titleCol.setText(entry.questTitle);

        // Column 3: Points badge
        const ptsCol = row.createEl('span', { cls: 'quests-timeline-points' });
        ptsCol.setText('+' + entry.points);

        // ── Expanded description (hidden by default) ───────────────────────
        const desc = li.createEl('div', {
          cls: 'quests-timeline-desc',
          text: entry.description || '',
        });

        // ── Toggle on click ───────────────────────────────────────────────
        li.addEventListener('click', (e) => {
          if (window.getSelection().toString().length > 0) return;
          li.classList.toggle('is-expanded');
        });
      }
    } else {
      contentEl.createEl('p', { text: 'No completed quests yet.', cls: 'quests-empty' });
    }

    // ── Total points ───────────────────────────────────────────────────────
    const total = state.totalPoints || 0;
    contentEl.createEl('hr');
    contentEl.createEl('p', {
      text: '⭐ Total: ' + total + ' points',
      cls: 'quests-total',
    });
  }

  async onClose() {
    // no-op
  }
}
