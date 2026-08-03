// Settings screen: daily window, rhythm, snooze, notifications, backup.

import { getSettings, saveSettings, updateToday } from './state.js';
import { RHYTHMS, SNOOZE_OPTIONS } from './schedule.js';
import { getAll, importAll } from './db.js';
import { registerScreen, showScreen, el, toast } from './ui.js';
import {
  permissionState, enableNotifications, hasServer, syncSchedule, syncDayAction,
} from './notify.js';

function segButtons(container, options, selected, onPick) {
  container.replaceChildren(
    ...options.map(({ key, label }) =>
      el('button', {
        class: key === selected ? 'on' : '',
        role: 'radio', 'aria-checked': String(key === selected),
        onclick: () => onPick(key),
      }, label)
    )
  );
}

async function render() {
  const s = getSettings();
  document.getElementById('set-start').value = s.startTime;
  document.getElementById('set-end').value = s.endTime;

  segButtons(
    document.getElementById('set-rhythm'),
    Object.entries(RHYTHMS).map(([key, { label }]) => ({ key, label })),
    s.rhythm,
    (rhythm) => { saveSettings({ rhythm }); syncSchedule(); render(); }
  );
  segButtons(
    document.getElementById('set-snooze'),
    SNOOZE_OPTIONS.map((min) => ({ key: String(min), label: `${min} min` })),
    String(s.snoozeMin),
    (min) => { saveSettings({ snoozeMin: Number(min) }); syncSchedule(); render(); }
  );

  const status = document.getElementById('notif-status');
  const perm = permissionState();
  const server = await hasServer();
  status.textContent =
    perm === 'granted' ? (server ? 'Push ✓' : 'Local only (no server)') :
    perm === 'denied' ? 'Blocked in system settings' :
    perm === 'unsupported' ? 'Add to Home Screen first' : 'Off';
  document.getElementById('notif-enable').hidden = perm === 'granted' || perm === 'denied';
}

export function initSettings() {
  document.getElementById('set-start').addEventListener('change', (e) => {
    saveSettings({ startTime: e.target.value });
    syncSchedule();
  });
  document.getElementById('set-end').addEventListener('change', (e) => {
    saveSettings({ endTime: e.target.value });
    syncSchedule();
  });

  document.getElementById('notif-enable').addEventListener('click', async () => {
    const result = await enableNotifications();
    toast(result === 'granted' ? 'Notifications on' : 'Not enabled');
    render();
  });

  document.getElementById('stop-today').addEventListener('click', () => {
    updateToday({ stopped: true });
    syncDayAction('stop');
    toast('Quiet until tomorrow');
    showScreen('screen-home');
  });

  // ── backup ──
  document.getElementById('export-btn').addEventListener('click', async () => {
    const backup = {
      app: 'companion', version: 1, exportedAt: new Date().toISOString(),
      reflections: await getAll(),
      // settings & feelings included so a restore feels complete:
      settings: getSettings(),
      feelings: JSON.parse(localStorage.getItem('feelings') ?? '{"list":[]}').list,
    };
    const blob = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
    const a = el('a', {
      href: URL.createObjectURL(blob),
      download: `companion-backup-${new Date().toISOString().slice(0, 10)}.json`,
    });
    a.click();
    URL.revokeObjectURL(a.href);
  });

  document.getElementById('import-btn').addEventListener('click', () =>
    document.getElementById('import-file').click()
  );
  document.getElementById('import-file').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    try {
      const backup = JSON.parse(await file.text());
      if (backup.app !== 'companion' || !Array.isArray(backup.reflections)) {
        throw new Error('not a companion backup');
      }
      const count = await importAll(backup.reflections);
      if (backup.settings) saveSettings(backup.settings);
      if (Array.isArray(backup.feelings)) {
        localStorage.setItem('feelings', JSON.stringify({ list: backup.feelings }));
      }
      toast(`Imported ${count} reflections`);
    } catch (err) {
      toast('Import failed — is this a Companion backup?');
      console.warn(err);
    }
    e.target.value = '';
  });

  registerScreen('screen-settings', { onShow: render });
}
