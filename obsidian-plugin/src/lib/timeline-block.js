import { MarkdownRenderChild } from 'obsidian';
import { getTimelineForDate } from '../core_wasm.js';

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
        text: `📜 No quests completed on ${this.year}-${String(this.month).padStart(2, '0')}-${String(this.day).padStart(2, '0')}.`,
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

      // Collapsed row (3 columns)
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

      // Expanded description
      const desc = li.createEl('div', {
        cls: 'quests-timeline-desc',
        text: entry.description || '',
      });

      // Toggle on click
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
