// Settings screen: daily window, rhythm, snooze, notifications, backup.

import { getSettings, saveSettings, updateToday, getFeelings, saveFeelings } from './state.js';
import { RHYTHMS, SNOOZE_OPTIONS } from './schedule.js';
import { getAll, importAll } from './db.js';
import { registerScreen, showScreen, el, toast } from './ui.js';
import { VERSION } from './version.js';
import {
  permissionState, enableNotifications, hasServer, syncSchedule, syncDayAction,
  ensurePushRegistered,
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
  document.getElementById('app-version').textContent = `Companion ${VERSION}`;

  segButtons(
    document.getElementById('set-rhythm'),
    Object.entries(RHYTHMS).map(([key, { label }]) => ({ key, label })),
    s.rhythm,
    (rhythm) => {
      if (!saveSettings({ rhythm })) toast("Couldn't save — is storage full?");
      syncSchedule();
      render();
    }
  );
  segButtons(
    document.getElementById('set-snooze'),
    SNOOZE_OPTIONS.map((min) => ({ key: String(min), label: `${min} min` })),
    String(s.snoozeMin),
    (min) => {
      if (!saveSettings({ snoozeMin: Number(min) })) toast("Couldn't save — is storage full?");
      syncSchedule();
      render();
    }
  );

  const status = document.getElementById('notif-status');
  const perm = permissionState();
  const server = await hasServer();
  // When the server is up, check how many subscriptions it holds so the row
  // can distinguish "registered" from "permission granted but this device is
  // NOT registered" — the silently-failed case this screen must surface.
  let detail = '';
  if (perm === 'granted' && server) {
    try {
      const res = await fetch('/api/status');
      if (res.ok) {
        const st = await res.json();
        detail =
          st.subscriptions >= 1
            ? ' (registered)'
            : ' — this device is NOT registered';
      }
    } catch {
      /* offline blip — keep the plain status text */
    }
  }
  status.textContent =
    perm === 'granted' ? (server ? `Push ✓${detail}` : 'Local only (no server)') :
    perm === 'denied' ? 'Blocked in system settings' :
    perm === 'unsupported' ? 'Add to Home Screen first' : 'Off';
  document.getElementById('notif-enable').hidden = perm === 'granted' || perm === 'denied';
}

export function initSettings() {
  document.getElementById('set-start').addEventListener('change', (e) => {
    if (!saveSettings({ startTime: e.target.value })) toast("Couldn't save — is storage full?");
    syncSchedule();
  });
  document.getElementById('set-end').addEventListener('change', (e) => {
    if (!saveSettings({ endTime: e.target.value })) toast("Couldn't save — is storage full?");
    syncSchedule();
  });

  document.getElementById('notif-enable').addEventListener('click', async () => {
    const result = await enableNotifications();
    const msg = {
      granted: 'Notifications on',
      'granted-unregistered': 'Notifications on, but not registered — check Status above',
      'granted-no-server': 'Notifications on — server offline, will retry next launch',
      denied: 'Notifications blocked — enable in system settings',
      unsupported: 'Add to Home Screen first',
    }[result] ?? 'Not enabled';
    toast(msg);
    render();
  });

  // Always visible recovery + diagnostics: surface the real error, don't
  // swallow it into a server log the user will never see.
  document.getElementById('notif-test').addEventListener('click', async () => {
    if (!(await hasServer())) {
      toast('No server — foreground reminders only');
      return;
    }
    try {
      const res = await fetch('/api/test-push', { method: 'POST' });
      const body = await res.json();
      const failed = (body.results ?? []).filter((r) => !r.ok);
      if (failed.length > 0) {
        toast(`Push: ${failed.length}/${body.sent_to ?? 0} failed — ${failed[0].error}`);
      } else {
        toast(`Test push sent to ${body.sent_to ?? 0} device(s)`);
      }
    } catch (err) {
      toast('Test push failed — is the server reachable?');
      console.warn(err);
    }
  });

  document.getElementById('notif-reregister').addEventListener('click', async () => {
    const ok = await ensurePushRegistered(true); // force a fresh subscription
    toast(ok ? 'Device re-registered' : 'Re-register failed — check Status above');
    render();
  });

  document.getElementById('stop-today').addEventListener('click', async () => {
    const saved = updateToday({ stopped: true });
    const synced = await syncDayAction('stop');
    if (!saved) toast("Couldn't save — is storage full?");
    else if (!synced) toast("Quiet until tomorrow — couldn't reach the server, the next reminder may still come");
    else toast('Quiet until tomorrow');
    showScreen('screen-home');
  });

  // ── backup ──
  document.getElementById('export-btn').addEventListener('click', async () => {
    try {
      const backup = {
        app: 'companion', version: 1, exportedAt: new Date().toISOString(),
        reflections: await getAll(),
        // settings & feelings included so a restore feels complete:
        settings: getSettings(),
        feelings: getFeelings(),
      };
      const blob = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
      const a = el('a', {
        href: URL.createObjectURL(blob),
        download: `companion-backup-${new Date().toISOString().slice(0, 10)}.json`,
      });
      a.click();
      URL.revokeObjectURL(a.href);
    } catch (err) {
      // A broken storage (private mode / quota) must not look like a fine export.
      console.warn('export failed', err);
      toast('Export failed — could not read storage');
    }
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
      let settingsSaved = true;
      if (backup.settings) settingsSaved = saveSettings(backup.settings) && settingsSaved;
      if (Array.isArray(backup.feelings)) settingsSaved = saveFeelings(backup.feelings) && settingsSaved;
      toast(settingsSaved
        ? `Imported ${count} reflections`
        : `Imported ${count} reflections — but couldn't save settings on this device`);
    } catch (err) {
      toast('Import failed — is this a Companion backup?');
      console.warn(err);
    }
    e.target.value = '';
  });

  registerScreen('screen-settings', { onShow: render });
}
