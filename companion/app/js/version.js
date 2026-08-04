// Single source of truth for the app version.
// Bump this on EVERY app change (see AGENTS.md): it busts the service-worker
// cache AND is shown in the Settings footer, so the phone always tells you
// which build it's running. sw.js imports it (module worker) — don't duplicate
// it anywhere, or the two copies will drift.

export const VERSION = 'v8';
