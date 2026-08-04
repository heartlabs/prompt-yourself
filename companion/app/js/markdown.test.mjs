// Pure markdown-format tests — markdown.js stays DOM-free so these run in
// plain node (see AGENTS.md "Testing").
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { reflectionToMarkdown } from './markdown.js';

// Local-time constructor round-tripped through UTC: deterministic in any TZ.
const at = (h, m) => new Date(2025, 0, 15, h, m).toISOString();

test('questions: combined record → energy emoji + 4 answers + feelings bullets', () => {
  const md = reflectionToMarkdown({
    type: 'questions', at: at(14, 32),
    data: {
      doing: 'writing', goal: 'shipping', progressing: 'yes', next: 'keep going',
      energy: 'yellow', values: { tired: 72, calm: 30 },
    },
  });
  assert.equal(md, [
    '### 14:32 — 5 Questions 🟡',
    '- **Doing:** writing',
    '- **Goal:** shipping',
    '- **Progressing:** yes',
    '- **Next:** keep going',
    '- tired: 72/100',
    '- calm: 30/100',
  ].join('\n'));
});

test('questions: no feelings on record → no bullet section', () => {
  const md = reflectionToMarkdown({
    type: 'questions', at: at(10, 0),
    data: { doing: 'coffee', energy: 'green', values: {} },
  });
  assert.equal(md, [
    '### 10:00 — 5 Questions 🟢',
    '- **Doing:** coffee',
  ].join('\n'));
});

test('questions: legacy records (text feeling, no energy) render as before', () => {
  const md = reflectionToMarkdown({
    type: 'questions', at: at(9, 5),
    data: { doing: 'walking', feeling: 'peaceful', next: 'stay outside' },
  });
  assert.equal(md, [
    '### 09:05 — 5 Questions',
    '- **Doing:** walking',
    '- **Feeling:** peaceful',
    '- **Next:** stay outside',
  ].join('\n'));
});

test('energy and feelings records are unchanged', () => {
  assert.equal(
    reflectionToMarkdown({ type: 'energy', at: at(8, 0), data: { level: 'green', note: 'fine' } }),
    '### 08:00 — Energy 🟢\nfine'
  );
  assert.equal(
    reflectionToMarkdown({ type: 'energy', at: at(8, 0), data: { level: 'red', note: '' } }),
    '### 08:00 — Energy 🔴'
  );
  assert.equal(
    reflectionToMarkdown({ type: 'feelings', at: at(20, 0), data: { values: { tired: 80 } } }),
    '### 20:00 — Feelings\n- tired: 80/100'
  );
});
