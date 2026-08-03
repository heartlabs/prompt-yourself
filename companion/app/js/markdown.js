// Reflection → Markdown, for pasting into the Prompt Yourself journal (Obsidian).
// Format is intentionally simple and stable — change it only deliberately,
// since users may build on it in their vaults.

const ENERGY_EMOJI = { green: '🟢', yellow: '🟡', red: '🔴' };

const QUESTION_LABELS = {
  doing: 'Doing',
  goal: 'Goal',
  progressing: 'Progressing',
  feeling: 'Feeling',
  next: 'Next',
};

function hhmm(iso) {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** One reflection as a `### HH:MM — …` block. */
export function reflectionToMarkdown(r) {
  const time = hhmm(r.at);
  switch (r.type) {
    case 'energy': {
      const head = `### ${time} — Energy ${ENERGY_EMOJI[r.data.level] ?? ''}`.trimEnd();
      return r.data.note ? `${head}\n${r.data.note}` : head;
    }
    case 'questions': {
      const lines = Object.entries(QUESTION_LABELS)
        .filter(([key]) => r.data[key])
        .map(([key, label]) => `- **${label}:** ${r.data[key]}`);
      return [`### ${time} — 5 Questions`, ...lines].join('\n');
    }
    case 'feelings': {
      const lines = Object.entries(r.data.values ?? {}).map(
        ([name, value]) => `- ${name}: ${value}/100`
      );
      return [`### ${time} — Feelings`, ...lines].join('\n');
    }
    default:
      return `### ${time} — ${r.type}`;
  }
}

/** All of one day's reflections under a `## YYYY-MM-DD` header. */
export function dayToMarkdown(day, reflections) {
  return [`## ${day}`, ...reflections.map(reflectionToMarkdown)].join('\n\n');
}

/** Full history as markdown (backup / bulk paste). */
export function allToMarkdown(reflections) {
  const byDay = new Map();
  for (const r of reflections) {
    if (!byDay.has(r.day)) byDay.set(r.day, []);
    byDay.get(r.day).push(r);
  }
  return [...byDay.entries()]
    .map(([day, list]) => dayToMarkdown(day, list))
    .join('\n\n');
}
