// IndexedDB access — the ONLY place that touches the reflections database.
// One object store "reflections", indexed by local day ("YYYY-MM-DD").
//
// Reflection record shape (see AGENTS.md for the contract):
//   { id: uuid, type: 'energy'|'questions'|'feelings', at: ISO string,
//     day: 'YYYY-MM-DD' (local), data: {...type-specific} }

const DB_NAME = 'companion';
const DB_VERSION = 1;
const STORE = 'reflections';

let dbPromise = null;

function open() {
  dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const store = req.result.createObjectStore(STORE, { keyPath: 'id' });
      store.createIndex('day', 'day');
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

/** Promisify a single IDBRequest. */
function done(req) {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

/** Local calendar day of a Date, as "YYYY-MM-DD". */
export function dayOf(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

export async function addReflection(type, data, when = new Date()) {
  const record = {
    id: crypto.randomUUID(),
    type,
    at: when.toISOString(),
    day: dayOf(when),
    data,
  };
  const db = await open();
  await done(db.transaction(STORE, 'readwrite').objectStore(STORE).add(record));
  return record;
}

/** All reflections of one local day, sorted by time. */
export async function getDay(day) {
  const db = await open();
  const rows = await done(
    db.transaction(STORE).objectStore(STORE).index('day').getAll(day)
  );
  return rows.sort((a, b) => a.at.localeCompare(b.at));
}

/** Map of day → records for a whole month ("YYYY-MM"). Used for calendar dots. */
export async function getMonth(yyyymm) {
  const db = await open();
  // Lexicographic day range: "-32" safely exceeds any real "-DD".
  const range = IDBKeyRange.bound(`${yyyymm}-01`, `${yyyymm}-32`);
  const rows = await done(
    db.transaction(STORE).objectStore(STORE).index('day').getAll(range)
  );
  const byDay = new Map();
  for (const r of rows) {
    if (!byDay.has(r.day)) byDay.set(r.day, []);
    byDay.get(r.day).push(r);
  }
  return byDay;
}

export async function getAll() {
  const db = await open();
  const rows = await done(db.transaction(STORE).objectStore(STORE).getAll());
  return rows.sort((a, b) => a.at.localeCompare(b.at));
}

/** Import records from a backup. Existing ids are overwritten (idempotent). */
export async function importAll(records) {
  const db = await open();
  const tx = db.transaction(STORE, 'readwrite');
  const store = tx.objectStore(STORE);
  let count = 0;
  for (const r of records) {
    if (r && r.id && r.type && r.at && r.day) {
      store.put(r);
      count++;
    }
  }
  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  return count;
}
