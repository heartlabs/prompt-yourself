// Small, non-historical state in localStorage: settings, today's flags,
// feelings slider positions, recent energy notes. History lives in db.js.

import { dayOf } from './db.js';

function read(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? { ...fallback, ...JSON.parse(raw) } : { ...fallback };
  } catch {
    return { ...fallback };
  }
}

function write(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (err) {
    // Never crash the app on a broken localStorage (private mode, quota).
    // Callers decide how loudly to surface it; every call site at least warns.
    console.warn(`localStorage write failed (${key})`, err);
    return false;
  }
}

// ── settings ──
const SETTINGS_DEFAULTS = {
  startTime: '09:00',
  endTime: '18:00',
  rhythm: 'hourly',   // key into schedule.js RHYTHMS
  snoozeMin: 10,
};

export function getSettings() {
  return read('settings', SETTINGS_DEFAULTS);
}

export function saveSettings(patch) {
  return write('settings', { ...getSettings(), ...patch });
}

// ── today (auto-resets when the date changes) ──
const TODAY_DEFAULTS = {
  date: '',
  committed: false,
  skipped: false,
  stopped: false,
  snoozeUntil: null,     // epoch ms, foreground timer only
  lastNotifiedSlot: null, // minutes-since-midnight of last foreground reminder
  endTime: null,          // today-only override, else settings.endTime
  rhythm: null,           // today-only override, else settings.rhythm
};

export function getToday() {
  const today = read('today', TODAY_DEFAULTS);
  const date = dayOf(new Date());
  if (today.date !== date) {
    const fresh = { ...TODAY_DEFAULTS, date };
    write('today', fresh);
    return fresh;
  }
  return today;
}

export function updateToday(patch) {
  return write('today', { ...getToday(), ...patch });
}

// ── feelings sliders (persist between sessions) ──
// [{ name: 'tired', value: 72 }] — value 0..100.

export function getFeelings() {
  return read('feelings', { list: [] }).list;
}

export function saveFeelings(list) {
  return write('feelings', { list });
}

// ── recent energy notes (one-tap chips) ──
const MAX_RECENT_NOTES = 5;

export function getRecentNotes() {
  return read('recentNotes', { list: [] }).list;
}

export function addRecentNote(text) {
  const trimmed = text.trim();
  if (!trimmed) return;
  const list = [trimmed, ...getRecentNotes().filter((n) => n !== trimmed)];
  write('recentNotes', { list: list.slice(0, MAX_RECENT_NOTES) });
}
