// The reflection flow: commitment → picker → (energy | questions | feelings) → picker.
// Each reflection saves via db.addReflection and returns to the picker,
// which dims what's already done in this session.

import { addReflection, importAll } from './db.js';
import {
  getSettings, getToday, updateToday,
  getFeelings, saveFeelings, getRecentNotes, addRecentNote,
} from './state.js';
import { RHYTHMS } from './schedule.js';
import { registerScreen, showScreen, el, toast } from './ui.js';
import { syncDayAction } from './notify.js';

const GOAL_EXAMPLES = ['relaxing', 'having fun', 'regaining energy', 'existing, no goal'];

const REFLECTIONS = [
  { type: 'energy',    emoji: '🚦', title: 'Energy check-in', blurb: 'One tap · a few words if you like' },
  { type: 'questions', emoji: '🖐', title: '5 Questions',     blurb: 'What am I doing, and why? ~2 min' },
  { type: 'feelings',  emoji: '🌊', title: 'Feelings',        blurb: 'Adjust your sliders · ~1 min' },
];

/** Reflection types finished in this picker session (dimmed, still tappable). */
let doneThisSession = new Set();
let pendingEnergyRecord = null; // saved energy record awaiting its optional note

/**
 * Guarded reflection save: a storage failure must never look like a saved
 * reflection. Toasts + warns so the user knows, returns null so the caller
 * can stay on the screen and retry instead of losing input.
 */
async function saveReflection(type, data) {
  try {
    return await addReflection(type, data);
  } catch (err) {
    console.warn('reflection save failed', err);
    toast("Couldn't save — is storage full?");
    return null;
  }
}

export function openPickerFresh() {
  doneThisSession = new Set();
  showScreen('screen-picker');
}

/** Entry point when arriving from a notification (or Shortcuts automation). */
export function openFromNotification() {
  const today = getToday();
  if (!today.committed && !today.skipped) {
    showScreen('screen-commit');
  } else {
    openPickerFresh();
  }
}

// ── commitment ──

function renderCommit() {
  const s = getSettings();
  const today = getToday();
  document.getElementById('commit-greeting').textContent =
    new Date().getHours() < 12 ? 'Good morning. Reflect today?' : 'Reflect today?';
  document.getElementById('commit-end').value = today.endTime ?? s.endTime;

  const select = document.getElementById('commit-rhythm');
  select.replaceChildren(
    ...Object.entries(RHYTHMS).map(([key, { label }]) =>
      el('option', { value: key, ...(key === (today.rhythm ?? s.rhythm) ? { selected: '' } : {}) }, label)
    )
  );
}

function initCommit() {
  document.getElementById('commit-yes').addEventListener('click', async () => {
    const endTime = document.getElementById('commit-end').value;
    const rhythm = document.getElementById('commit-rhythm').value;
    if (!updateToday({ committed: true, endTime, rhythm })) {
      // Commit is only a flag; the reflection flow itself still works — warn,
      // don't block (the picker must open either way).
      toast("Couldn't save — is storage full?");
    }
    const [h, m] = endTime.split(':').map(Number);
    syncDayAction('commit', { end_min: h * 60 + m, rhythm });
    openPickerFresh();
  });
  document.getElementById('commit-skip').addEventListener('click', async () => {
    const saved = updateToday({ skipped: true });
    const synced = await syncDayAction('skip');
    if (!saved) toast("Couldn't save — is storage full?");
    else if (!synced) toast("Skipped — couldn't reach the server, the next reminder may still come");
    else toast('Skipped — see you tomorrow');
    showScreen('screen-home');
  });
  registerScreen('screen-commit', { onShow: renderCommit });
}

// ── picker ──

function renderPicker() {
  const nav = document.getElementById('picker-options');
  nav.replaceChildren(
    ...REFLECTIONS.map(({ type, emoji, title, blurb }) => {
      const isDone = doneThisSession.has(type);
      return el(
        'button',
        { class: `opt ${isDone ? 'done' : ''}`, onclick: () => startReflection(type) },
        el('span', { class: 'emoji' }, emoji),
        el(
          'span',
          {},
          el('b', {}, title),
          el('small', {}, isDone ? 'Done just now · tap to redo' : blurb)
        )
      );
    })
  );
}

function startReflection(type) {
  showScreen(`screen-${type}`); // section ids match reflection types by convention
}

function finishReflection(type) {
  doneThisSession.add(type);
  toast('Saved');
  showScreen('screen-picker');
}

// ── energy ──

function initEnergy() {
  for (const btn of document.querySelectorAll('#screen-energy .light')) {
    btn.addEventListener('click', async () => {
      // Tap = saved. The note screen only enriches the already-saved record.
      pendingEnergyRecord = await saveReflection('energy', { level: btn.dataset.level, note: '' });
      if (pendingEnergyRecord) showScreen('screen-energy-note');
    });
  }

  registerScreen('screen-energy-note', {
    onShow() {
      const level = pendingEnergyRecord?.data.level ?? '';
      document.getElementById('note-title').textContent =
        `${level.charAt(0).toUpperCase()}${level.slice(1)} — a few words?`;
      document.getElementById('note-text').value = '';

      const chips = document.getElementById('note-chips');
      const recent = getRecentNotes();
      document.getElementById('note-chips-title').hidden = recent.length === 0;
      chips.replaceChildren(
        ...recent.map((text) =>
          el('button', { class: 'chip', onclick: () => {
            const ta = document.getElementById('note-text');
            ta.value = ta.value ? `${ta.value} ${text}` : text;
            ta.focus();
          } }, text)
        )
      );
    },
  });

  const saveNote = async (note) => {
    if (note && pendingEnergyRecord) {
      // Rewrite the record with the note (put overwrites by id).
      pendingEnergyRecord.data.note = note;
      try {
        await importAll([pendingEnergyRecord]);
        addRecentNote(note);
      } catch (err) {
        console.warn('note save failed', err);
        toast("Couldn't save — is storage full?");
        return; // keep the note on screen — Done to retry, Skip to discard
      }
    }
    pendingEnergyRecord = null;
    finishReflection('energy');
  };
  document.getElementById('note-done').addEventListener('click', () =>
    saveNote(document.getElementById('note-text').value.trim())
  );
  document.getElementById('note-skip').addEventListener('click', () => saveNote(''));
}

// ── 5 questions ──

function initQuestions() {
  const form = document.getElementById('questions-form');

  document.getElementById('goal-chips').replaceChildren(
    ...GOAL_EXAMPLES.map((text) =>
      el('button', { class: 'chip', type: 'button', onclick: () => {
        const field = form.elements.goal;
        field.value = field.value ? `${field.value} ${text}` : text;
      } }, text)
    )
  );

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const data = Object.fromEntries(
      ['doing', 'goal', 'progressing', 'feeling', 'next'].map((k) => [k, form.elements[k].value.trim()])
    );
    if (!Object.values(data).some(Boolean)) return toast('Write at least one answer');
    const saved = await saveReflection('questions', data);
    if (!saved) return; // keep the answers on screen
    form.reset();
    finishReflection('questions');
  });

  registerScreen('screen-questions', { onShow: () => form.reset() });
}

// ── feelings ──

function renderFeelings() {
  const list = document.getElementById('feelings-list');
  const feelings = getFeelings();
  list.replaceChildren(
    ...feelings.map(({ name, value }, index) =>
      el(
        'li',
        { class: 'feel' },
        el(
          'div',
          { class: 'top' },
          el('b', {}, name),
          el('button', { class: 'x', 'aria-label': `Remove ${name}`, onclick: () => {
            feelings.splice(index, 1);
            saveFeelings(feelings);
            renderFeelings();
          } }, '✕')
        ),
        el('input', {
          type: 'range', min: '0', max: '100', value: String(value),
          'aria-label': `Intensity of ${name}`,
          oninput: (e) => {
            feelings[index].value = Number(e.target.value);
            saveFeelings(feelings); // persist as they slide — sliders survive sessions
          },
        })
      )
    )
  );
}

function initFeelings() {
  document.getElementById('feeling-add-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const input = document.getElementById('feeling-add');
    const name = input.value.trim();
    if (!name) return;
    const feelings = getFeelings();
    if (!feelings.some((f) => f.name === name)) {
      feelings.push({ name, value: 50 });
      saveFeelings(feelings);
      renderFeelings();
    }
    input.value = '';
    input.focus(); // chain several adds without reaching for the input again
  });

  document.getElementById('feelings-save').addEventListener('click', async () => {
    const feelings = getFeelings();
    if (!feelings.length) return toast('Add a feeling first');
    const values = Object.fromEntries(feelings.map((f) => [f.name, f.value]));
    const saved = await saveReflection('feelings', { values });
    if (!saved) return;
    finishReflection('feelings');
  });

  registerScreen('screen-feelings', { onShow: renderFeelings });
}

// ── wiring ──

export function initReflect() {
  registerScreen('screen-picker', { onShow: renderPicker });
  initCommit();
  initEnergy();
  initQuestions();
  initFeelings();
}
