import { ItemView } from 'obsidian';
import { QUEST_VIEW_TYPE } from './constants.js';
import { getGameState } from '../core_wasm.js';

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
    this.render();
  }

  render() {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.addClass('prompt-yourself-quests');

    let state;
    try {
      const json = getGameState();
      state = JSON.parse(json);
    } catch (e) {
      contentEl.createEl('p', { text: '⏳ Loading quests…' });
      setTimeout(() => this.render(), 500);
      return;
    }

    // Header
    contentEl.createEl('h2', { text: '🏆 Quests' });

    // Open quests
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

    // Completed quests
    const completed = state.completedQuests || [];
    if (completed.length > 0) {
      contentEl.createEl('h3', { text: 'Completed (' + completed.length + ')' });
      const completedList = contentEl.createEl('ul');
      for (const q of completed) {
        const li = completedList.createEl('li', { cls: 'quests-completed' });
        li.createEl('strong', { text: q.title });
        li.appendText(' — ' + q.description + ' (' + q.points + ' pts)');
      }
    }

    // Total points
    const total = state.totalPoints || 0;
    contentEl.createEl('hr');
    contentEl.createEl('p', {
      text: 'Total: ' + total + ' points',
      cls: 'quests-total',
    });
  }

  async onClose() {
    // no-op
  }
}
