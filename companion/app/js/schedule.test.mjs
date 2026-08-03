// Run with: node --test app/js/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { slotTimes, dueSlot, toMinutes, toHHMM } from './schedule.js';

test('time conversions round-trip', () => {
  assert.equal(toMinutes('09:30'), 570);
  assert.equal(toHHMM(570), '09:30');
  assert.equal(toHHMM(toMinutes('00:05')), '00:05');
});

test('hourly slots span the window inclusively', () => {
  assert.deepEqual(slotTimes(540, 720, 'hourly'), [540, 600, 660, 720]);
});

test('3x/day is start, middle, end', () => {
  assert.deepEqual(slotTimes(540, 1080, '3x'), [540, 810, 1080]);
});

test('degenerate window yields one slot', () => {
  assert.deepEqual(slotTimes(600, 600, 'hourly'), [600]);
  assert.deepEqual(slotTimes(600, 500, '30min'), [600]);
});

test('dueSlot picks only the latest missed slot (silent replace)', () => {
  // now = 11:35, hourly 9–18, never notified → due is 11:00, not 9 or 10.
  assert.equal(dueSlot(695, 540, 1080, 'hourly', null), 660);
});

test('dueSlot is null before the window and after firing', () => {
  assert.equal(dueSlot(500, 540, 1080, 'hourly', null), null);
  assert.equal(dueSlot(695, 540, 1080, 'hourly', 660), null);
});
