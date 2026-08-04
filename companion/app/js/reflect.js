// The reflection flow: commitment → picker → reflection → picker.
// The 5 Questions flow spans two screens (traffic light → questions) and is
// the full check-in; energy and feelings stay standalone light versions.
// Each reflection saves via db.addReflection and returns to the picker,
// which dims what's already done in this session.

import { addReflection, importAll } from './db.js';
import {
  getSettings, getToday, updateToday,
  getFeelings, saveFeelings, getRecentNotes, addRecentNote,
  getRecentAnswers, addRecentAnswer,
} from './state.js';
import { RHYTHMS } from './schedule.js';
import { registerScreen, showScreen, el, toast } from './ui.js';
import { syncDayAction } from './notify.js';

// Fixed one-tap quick answers for "Am I progressing?" — always shown. The
// other text questions get chips fed from your past answers (see below).
const PROGRESSING_EXAMPLES = ['sure', 'probably', 'maybe', 'not really', 'no'];
/** Questions with dynamic recent-answer chips (past answers, newest first). */
const CHIP_FIELDS = ['doing', 'goal', 'next'];

const REFLECTIONS = [
  { type: 'energy',    emoji: '🚦', title: 'Energy check-in', blurb: 'One tap · a few words if you like' },
  { type: 'questions', emoji: '🖐', title: '5 Questions',     blurb: 'The full check-in: energy, feelings, 5 questions · ~3 min' },
  { type: 'feelings',  emoji: '🌊', title: 'Feelings',        blurb: 'Adjust your sliders · ~1 min' },
];

/** Reflection types finished in this picker session (dimmed, still tappable). */
let doneThisSession = new Set();
let pendingEnergyRecord = null; // saved energy record awaiting its optional note
let energyMode = 'light';       // what the energy screen is part of: standalone or the 5 Questions flow
let questionsEnergy = null;     // tapped light, held until the questions record saves

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
  if (type === 'questions') {
    // The big flow starts on the traffic light. No note step: the tap is held
    // until the questions record saves, so abandoning the flow saves nothing.
    energyMode = 'questions';
    questionsEnergy = null;
    showScreen('screen-energy');
    return;
  }
  energyMode = 'light';
  showScreen(`screen-${type}`); // section ids match reflection types by convention
}

function finishReflection(type) {
  doneThisSession.add(type);
  toast('Saved');
  showScreen('screen-picker');
}

// ── energy ──

/** The energy screen is shared by both flows: standalone (tap = saved record)
 *  and the 5 Questions entry (tap = held selection, highlighted, no note).
 *  Re-rendered on show so the picked light stays visible when returning via Back. */
function renderEnergyScreen() {
  const inQuestionsFlow = energyMode === 'questions';
  document.getElementById('energy-hint').hidden = !inQuestionsFlow;
  for (const btn of document.querySelectorAll('#screen-energy .light')) {
    btn.classList.toggle('sel', inQuestionsFlow && btn.dataset.level === questionsEnergy);
  }
}

function initEnergy() {
  for (const btn of document.querySelectorAll('#screen-energy .light')) {
    btn.addEventListener('click', async () => {
      if (energyMode === 'questions') {
        // Hold the selection; the record is written with the questions on save.
        questionsEnergy = btn.dataset.level;
        showScreen('screen-questions');
        return;
      }
      // Standalone: tap = saved. The note screen only enriches the record.
      pendingEnergyRecord = await saveReflection('energy', { level: btn.dataset.level, note: '' });
      if (pendingEnergyRecord) showScreen('screen-energy-note');
    });
  }
  registerScreen('screen-energy', { onShow: renderEnergyScreen });

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
// The full reflection: traffic light (energy) + 4 written answers + the same
// feelings sliders as the standalone screen (shared store, see state.js).
// Everything lands in ONE record: { doing, goal, progressing, next, energy,
// values }. Energy and feelings are both mandatory.

function initQuestions() {
  const form = document.getElementById('questions-form');

  // One-tap chips under each text question. doing/goal/next feed from past
  // answers (localStorage, like the energy-note chips); progressing always
  // shows the fixed quick answers. Tapping appends to that question's box.
  const chip = (field, text) =>
    el('button', { class: 'chip', type: 'button', onclick: () => {
      const ta = form.elements[field];
      ta.value = ta.value ? `${ta.value} ${text}` : text;
      ta.focus();
    } }, text);

  function renderQuestionChips() {
    for (const field of CHIP_FIELDS) {
      const row = document.getElementById(`chips-${field}`);
      const recent = getRecentAnswers(field);
      row.replaceChildren(...recent.map((text) => chip(field, text)));
      row.hidden = recent.length === 0; // no history yet — keep the form tight
    }
    document.getElementById('chips-progressing').replaceChildren(
      ...PROGRESSING_EXAMPLES.map((text) => chip('progressing', text))
    );
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    // The 4 written answers; "How am I feeling?" is the sliders below.
    const data = {
      doing: form.elements.doing.value.trim(),
      goal: form.elements.goal.value.trim(),
      progressing: form.elements.progressing.value.trim(),
      next: form.elements.next.value.trim(),
    };
    if (!Object.values(data).some(Boolean)) return toast('Write at least one answer');
    const feelings = getFeelings();
    if (!feelings.length) return toast('Add a feeling first');
    if (!questionsEnergy) return toast('Pick your energy first'); // unreachable via UI — guard
    data.energy = questionsEnergy;
    data.values = Object.fromEntries(feelings.map((f) => [f.name, f.value]));
    const saved = await saveReflection('questions', data);
    if (!saved) return; // keep the answers on screen
    // Feed the chip suggestions from this reflection's answers.
    for (const field of CHIP_FIELDS) addRecentAnswer(field, data[field]);
    form.reset();
    finishReflection('questions');
  });

  // Back returns to the traffic light (not the picker) so the energy can be
  // re-picked — the tapped light is highlighted there.
  document.getElementById('questions-back').addEventListener('click', () =>
    showScreen('screen-energy')
  );

  registerScreen('screen-questions', {
    onShow: () => {
      form.reset();
      renderQuestionChips();
      renderQuestionFeelings();
    },
  });
}

// ── feelings ──

/** One slider list, shared by the standalone screen and the 5 Questions form.
 *  Both render and write the SAME store (state.js getFeelings/saveFeelings),
 *  so adding/removing/sliding anywhere shows up identically everywhere. */
function renderFeelingsList(container) {
  const feelings = getFeelings();
  container.replaceChildren(
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
            renderFeelingsList(container);
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

const renderFeelings = () => renderFeelingsList(document.getElementById('feelings-list'));
const renderQuestionFeelings = () => renderFeelingsList(document.getElementById('q-feelings-list'));

/** Add a feeling to the shared store (no dupes), then re-render. */
function addFeeling(name, render) {
  const trimmed = name.trim();
  if (!trimmed) return;
  const feelings = getFeelings();
  if (!feelings.some((f) => f.name === trimmed)) {
    feelings.push({ name: trimmed, value: 50 });
    saveFeelings(feelings);
    render();
  }
}

function initFeelings() {
  document.getElementById('feeling-add-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const input = document.getElementById('feeling-add');
    addFeeling(input.value, renderFeelings);
    input.value = '';
    input.focus(); // chain several adds without reaching for the input again
  });

  // In the questions form there is no nested <form> (invalid HTML), so the
  // add-row is wired by hand; Enter must NOT submit the questions form.
  const qAddInput = document.getElementById('q-feeling-add');
  const addQuestionFeeling = () => {
    addFeeling(qAddInput.value, renderQuestionFeelings);
    qAddInput.value = '';
    qAddInput.focus();
  };
  document.getElementById('q-feeling-add-btn').addEventListener('click', addQuestionFeeling);
  qAddInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      addQuestionFeeling();
    }
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
