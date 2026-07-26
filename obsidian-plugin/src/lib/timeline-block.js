import { MarkdownRenderChild } from 'obsidian';
import { getTimelineForDate, updateTimelineEntryEnergy } from '../core_wasm.js';

/**
 * A live-updating markdown render child that displays a day's timeline entries.
 *
 * Re-renders every 10 seconds so the block stays in sync when quests are
 * completed or timeline entries are updated.
 */
export class TimelineBlockComponent extends MarkdownRenderChild {
  /**
   * @param {HTMLElement} containerEl
   * @param {number} year
   * @param {number} month  (1-based)
   * @param {number} day
   */
  constructor(containerEl, year, month, day) {
    super(containerEl);
    this.year = year;
    this.month = month;
    this.day = day;
    this._interval = null;
  }

  async onload() {
    // Auto-refresh every 10 seconds
    this._interval = setInterval(() => this.render(), 10_000);
    await this.render();
  }

  onunload() {
    if (this._interval) {
      clearInterval(this._interval);
      this._interval = null;
    }
  }

  async render() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.addClass('prompt-yourself-quests');
    containerEl.addClass('prompt-yourself-timeline-block');

    let data;
    try {
      const json = await getTimelineForDate(this.year, this.month, this.day);
      data = JSON.parse(json);
    } catch (e) {
      containerEl.createEl('p', { text: '⏳ Timeline loading…', cls: 'quests-empty' });
      return;
    }

    const timeline = data.timeline || [];

    if (timeline.length === 0) {
      containerEl.createEl('p', {
        text: `📜 No entries on ${this.year}-${String(this.month).padStart(2, '0')}-${String(this.day).padStart(2, '0')}.`,
        cls: 'quests-empty',
      });
      return;
    }

    // Header
    const dateStr = `${String(this.day).padStart(2, '0')}/${String(this.month).padStart(2, '0')}/${this.year}`;
    containerEl.createEl('h3', {
      text: `📜 Timeline — ${dateStr} (${timeline.length})`,
    });

    const timelineList = containerEl.createEl('ul', { cls: 'quests-timeline' });

    for (const entry of timeline) {
      const li = timelineList.createEl('li', { cls: 'quests-timeline-entry' });

      // Collapsed row
      const row = li.createEl('div', { cls: 'quests-timeline-row' });

      // Energy dot (check-in only)
      if (entry.type === 'check_in' && entry.energyLevel) {
        const energyEl = row.createEl('span', {
          cls: `quests-timeline-energy energy-${entry.energyLevel}`,
        });
        energyEl.setAttr('data-entry-id', entry.id);

        // Click to open dropdown
        energyEl.addEventListener('click', (e) => {
          e.stopPropagation();
          this._showEnergyDropdown(energyEl, entry.id, entry.energyLevel);
        });
      }

      // Column 1: Timestamp
      const timeCol = row.createEl('span', { cls: 'quests-timeline-time' });
      timeCol.setText(formatTimestamp(entry.occurredOn));

      // Column 2: Description
      const descCol = row.createEl('span', { cls: 'quests-timeline-title' });
      descCol.setText(entry.description);

      // Column 3: Points badge
      const ptsCol = row.createEl('span', { cls: 'quests-timeline-points' });
      ptsCol.setText('+' + entry.points);

      // Expanded detail (none for now — description is always visible)
      li.createEl('div', { cls: 'quests-timeline-desc', text: '' });

      // Toggle on click (skip if user clicked the energy dot — already stopped)
      li.addEventListener('click', (e) => {
        if (window.getSelection().toString().length > 0) return;
        li.classList.toggle('is-expanded');
      });
    }

    // Total points
    const total = data.totalPoints || 0;
    containerEl.createEl('hr');
    containerEl.createEl('p', {
      text: '⭐ Total: ' + total + ' points',
      cls: 'quests-total',
    });
  }

  /**
   * Show an inline dropdown to change the energy level of a check-in entry.
   * @param {HTMLElement} anchorEl - the energy dot element
   * @param {string} entryId
   * @param {string} currentLevel - "green" | "yellow" | "red"
   */
  _showEnergyDropdown(anchorEl, entryId, currentLevel) {
    // Remove any existing dropdown
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

    // Clicking outside removes the dropdown
    const closeOnOutside = (e) => {
      if (!anchorEl.contains(e.target)) {
        popup.remove();
        document.removeEventListener('click', closeOnOutside, true);
      }
    };
    // Attach on the next tick so the current click doesn't close it immediately
    setTimeout(() => document.addEventListener('click', closeOnOutside, true), 0);
  }
}

/**
 * Format an RFC3339 timestamp string to hh:mm:ss (local time).
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
