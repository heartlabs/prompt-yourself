// Pure schedule math. No DOM, no storage — testable with `node --test`.
// The Rust server mirrors this logic (server/src/main.rs slot_times) — keep in sync.

export const RHYTHMS = {
  '30min':  { label: '30 min' },
  'hourly': { label: 'Hourly' },
  '2h':     { label: '2 h' },
  '3x':     { label: '3×/day' },
  '1x':     { label: '1×/day' },
};

export const SNOOZE_OPTIONS = [5, 10, 30]; // minutes

/** "09:30" → 570 (minutes since midnight). */
export function toMinutes(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

/** 570 → "09:30". */
export function toHHMM(minutes) {
  const h = String(Math.floor(minutes / 60)).padStart(2, '0');
  const m = String(minutes % 60).padStart(2, '0');
  return `${h}:${m}`;
}

/** All notification slots for a day, as minutes since midnight. */
export function slotTimes(startMin, endMin, rhythm) {
  if (endMin <= startMin) return [startMin];
  const interval = (step) => {
    const out = [];
    for (let t = startMin; t <= endMin; t += step) out.push(t);
    return out;
  };
  switch (rhythm) {
    case '30min':  return interval(30);
    case 'hourly': return interval(60);
    case '2h':     return interval(120);
    case '3x':     return [startMin, startMin + Math.floor((endMin - startMin) / 2), endMin];
    case '1x':     return [startMin];
    default:       return interval(60);
  }
}

/**
 * The slot the user should be notified for right now, or null.
 * Missed slots are silently replaced: only the latest due slot counts.
 * `lastNotified` is the slot we already fired for today (or null).
 */
export function dueSlot(nowMin, startMin, endMin, rhythm, lastNotified) {
  const due = slotTimes(startMin, endMin, rhythm).filter((s) => s <= nowMin).at(-1);
  if (due === undefined) return null;
  if (lastNotified !== null && lastNotified >= due) return null;
  return due;
}
