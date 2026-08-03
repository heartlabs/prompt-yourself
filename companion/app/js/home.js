// Home screen: month calendar with tracked-day dots + selected day's timeline.
// Also owns the read-only detail screen (they share data).

import { getMonth, getDay, dayOf } from './db.js';
import { reflectionToMarkdown, dayToMarkdown } from './markdown.js';
import { registerScreen, showScreen, el, toast, copyToClipboard } from './ui.js';

const TYPE_LABEL = { energy: 'Energy', questions: '5 Questions', feelings: 'Feelings' };
// Worst energy of the day wins the calendar dot color.
const ENERGY_RANK = { red: 3, yellow: 2, green: 1 };

let shownMonth = startOfMonth(new Date()); // Date at day 1 of the visible month
let selectedDay = dayOf(new Date());       // 'YYYY-MM-DD'
let detailReflection = null;               // record shown on the detail screen

function startOfMonth(d) {
  return new Date(d.getFullYear(), d.getMonth(), 1);
}

function monthKey(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

async function renderCalendar() {
  const grid = document.getElementById('cal-grid');
  const title = document.getElementById('cal-title');
  title.textContent = shownMonth.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });

  const byDay = await getMonth(monthKey(shownMonth));
  grid.replaceChildren();

  for (const dow of ['M', 'T', 'W', 'T', 'F', 'S', 'S']) {
    grid.append(el('span', { class: 'dow' }, dow));
  }

  // Monday-first offset for the 1st of the month.
  const firstDow = (shownMonth.getDay() + 6) % 7;
  for (let i = 0; i < firstDow; i++) grid.append(el('span'));

  const daysInMonth = new Date(shownMonth.getFullYear(), shownMonth.getMonth() + 1, 0).getDate();
  for (let n = 1; n <= daysInMonth; n++) {
    const day = `${monthKey(shownMonth)}-${String(n).padStart(2, '0')}`;
    const records = byDay.get(day) ?? [];

    // Neutral dot when tracked; tinted only by energy check-ins (worst of day).
    let dotClass = records.length ? 'has' : '';
    const energies = records.filter((r) => r.type === 'energy').map((r) => r.data.level);
    if (energies.length) {
      dotClass = energies.sort((a, b) => ENERGY_RANK[b] - ENERGY_RANK[a])[0];
    }

    const cell = el(
      'button',
      {
        class: `d ${dotClass} ${day === selectedDay ? 'sel' : ''}`,
        onclick: () => {
          selectedDay = day;
          renderCalendar();
          renderTimeline();
        },
      },
      String(n),
      el('span', { class: 'dot' })
    );
    grid.append(cell);
  }
}

async function renderTimeline() {
  const list = document.getElementById('day-timeline');
  const title = document.getElementById('day-title');
  const records = await getDay(selectedDay);

  const dayDate = new Date(`${selectedDay}T12:00:00`);
  const dayLabel = dayDate.toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' });
  title.textContent = records.length
    ? `${dayLabel} · ${records.length} reflection${records.length > 1 ? 's' : ''}`
    : `${dayLabel} · nothing yet`;

  list.replaceChildren(
    ...records.map((r) => {
      const time = new Date(r.at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });
      const pip = el('span', { class: `pip ${r.type === 'energy' ? r.data.level : 'n'}` });
      return el(
        'li',
        {},
        el(
          'button',
          { class: 'row', onclick: () => openDetail(r) },
          el('time', {}, time),
          pip,
          el('span', { class: 'what' }, summaryLine(r))
        )
      );
    })
  );
}

function summaryLine(r) {
  switch (r.type) {
    case 'energy':
      return `Energy · ${r.data.note || r.data.level}`;
    case 'questions':
      return `5 Questions · ${r.data.doing || '—'}`;
    case 'feelings':
      return `Feelings · ${Object.keys(r.data.values ?? {}).length} tracked`;
    default:
      return r.type;
  }
}

// ── detail screen ──

function openDetail(r) {
  detailReflection = r;
  showScreen('screen-detail');
}

function renderDetail() {
  const r = detailReflection;
  if (!r) return showScreen('screen-home');
  const body = document.getElementById('detail-body');
  const when = new Date(r.at);
  const meta = when.toLocaleString(undefined, {
    weekday: 'long', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  });

  const parts = [el('h3', {}, TYPE_LABEL[r.type] ?? r.type), el('p', { class: 'meta' }, meta)];

  if (r.type === 'energy') {
    parts.push(qa('Level', r.data.level));
    if (r.data.note) parts.push(qa('Note', r.data.note));
  } else if (r.type === 'questions') {
    const labels = {
      doing: 'Doing right now', goal: 'With what goal', progressing: 'Progressing?',
      feeling: 'Feeling', next: 'Continue or change?',
    };
    for (const [key, label] of Object.entries(labels)) {
      if (r.data[key]) parts.push(qa(label, r.data[key]));
    }
  } else if (r.type === 'feelings') {
    for (const [name, value] of Object.entries(r.data.values ?? {})) {
      parts.push(qa(name, `${value}/100`));
    }
  }
  body.replaceChildren(...parts);
}

function qa(question, answer) {
  return el('div', { class: 'qa' }, el('div', { class: 'q' }, question), el('div', { class: 'a' }, answer));
}

// ── wiring ──

export function initHome() {
  document.getElementById('cal-prev').addEventListener('click', () => {
    shownMonth = new Date(shownMonth.getFullYear(), shownMonth.getMonth() - 1, 1);
    renderCalendar();
  });
  document.getElementById('cal-next').addEventListener('click', () => {
    shownMonth = new Date(shownMonth.getFullYear(), shownMonth.getMonth() + 1, 1);
    renderCalendar();
  });

  document.getElementById('detail-copy').addEventListener('click', async () => {
    if (!detailReflection) return;
    const ok = await copyToClipboard(reflectionToMarkdown(detailReflection));
    toast(ok ? 'Copied — paste into your journal' : 'Copy failed');
  });

  registerScreen('screen-home', {
    onShow() {
      renderCalendar();
      renderTimeline();
    },
  });
  registerScreen('screen-detail', { onShow: renderDetail });
}

/** Used by export: markdown for one whole day. */
export { dayToMarkdown };
