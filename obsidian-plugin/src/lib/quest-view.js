import { ItemView } from 'obsidian';
import { QUEST_VIEW_TYPE } from './constants.js';
import { getGameState, updateTimelineEntryEnergy } from '../core_wasm.js';

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

        // ── Collapsed row ───────────────────────────────────────────────────
        const row = li.createEl('div', { cls: 'quests-timeline-row' });

        // Energy dot (check-in only) — replaces the default blue dot
        if (entry.type === 'check_in' && entry.energyLevel) {
          li.addClass('is-energy');
          const energyEl = row.createEl('span', {
            cls: `quests-timeline-energy energy-${entry.energyLevel}`,
          });
          energyEl.setAttr('data-entry-id', entry.id);

          energyEl.addEventListener('click', (e) => {
            e.stopPropagation();
            this._showEnergyDropdown(energyEl, entry.id, entry.energyLevel);
          });
        }

        // Column 1: Timestamp
        const timeCol = row.createEl('span', { cls: 'quests-timeline-time' });
        timeCol.setText(formatTimestamp(entry.occurredOn));

        // Column 2: Description
        const titleCol = row.createEl('span', { cls: 'quests-timeline-title' });
        titleCol.setText(entry.description);

        // Column 3: Points badge
        const ptsCol = row.createEl('span', { cls: 'quests-timeline-points' });
        ptsCol.setText('+' + entry.points);

        // ── Expanded description (hidden by default) ────────────────────────
        const desc = li.createEl('div', {
          cls: 'quests-timeline-desc',
          text: '',
        });

        // ── Toggle on click ───────────────────────────────────────────────
        li.addEventListener('click', (e) => {
          if (window.getSelection().toString().length > 0) return;
          li.classList.toggle('is-expanded');
        });
      }
    } else {
      contentEl.createEl('p', { text: 'No entries yet today.', cls: 'quests-empty' });
    }

    // ── Total points ───────────────────────────────────────────────────────
    const total = state.totalPoints || 0;
    contentEl.createEl('hr');
    contentEl.createEl('p', {
      text: '⭐ Total: ' + total + ' points',
      cls: 'quests-total',
    });
  }

  /**
   * Show an inline dropdown to change the energy level of a check-in entry.
   */
  _showEnergyDropdown(anchorEl, entryId, currentLevel) {
    const existing = anchorEl.querySelector('.quests-energy-dropdown');
    if (existing) return;

    const popup = anchorEl.createEl('div', { cls: 'quests-energy-dropdown' });
    const levels = ['green', 'yellow', 'red'];

    for (const l of levels) {
      const dot = popup.createEl('div', {
        cls: `quests-energy-dot energy-${l}${l === currentLevel ? ' is-current' : ''}`,
      });

      dot.addEventListener('click', async (e) => {
        e.stopPropagation();
        if (l === currentLevel) {
          popup.remove();
          return;
        }
        try {
          await updateTimelineEntryEnergy(entryId, l);
        } catch (err) {
          console.error('Failed to update energy level:', err);
        }
        popup.remove();
        this.render();
      });
    }

    const closeOnOutside = (e) => {
      if (!anchorEl.contains(e.target)) {
        popup.remove();
        document.removeEventListener('click', closeOnOutside, true);
      }
    };
    setTimeout(() => document.addEventListener('click', closeOnOutside, true), 0);
  }

  async onClose() {
    // no-op
  }
}
