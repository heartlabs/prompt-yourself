# Companion — Prompt Yourself companion

Micro-reflections on the go. A tiny PWA for the iPhone (and any browser) that
nudges you a few times a day to check in with yourself: energy traffic light,
5 questions, feelings sliders. Part of the
[Prompt Yourself](https://github.com/heartlabs/prompt-yourself) family.

**Local-first:** every reflection lives only in your browser (IndexedDB).
The optional Rust server exists solely to send push notifications — it stores
your schedule and a push subscription, never any reflection content.

```
companion/
├── app/       the entire PWA — static files, no build step, no dependencies
├── server/    optional Rust push server (also serves app/)
├── README.md  you are here
└── AGENTS.md  read this before changing code
```

## Quick start (no Rust needed)

Any static file server works. From the repo root:

```sh
npx serve app          # or: python3 -m http.server -d app 8990
```

Open http://localhost:8990. Everything works except background push
notifications: reflections, calendar, history, export, and foreground
reminders (which fire while the app is open — fine as a desk pomodoro).

## Full setup with push notifications

Background pushes on an iPhone require all of:

1. **The Rust server running** (sends Web Push on your schedule)
2. **HTTPS** with a certificate the phone trusts (iOS refuses push otherwise)
3. **App added to the Home Screen** (Share → *Add to Home Screen*) — iOS only
   allows Web Push for installed PWAs
4. **Notifications enabled from a button tap** (Settings → Enable notifications)

### 1. Run the server

```sh
cd server
cargo run --release     # listens on :8990, serves ../app at /
```

On first run it generates a VAPID keypair into `companion-state.json`
(created in the working directory — keep that file, it also holds your
subscription and schedule). `PORT=9000 cargo run` to change the port.

### 2. Get HTTPS in front of it

Pick whichever is easiest for you tonight:

- **Tailscale (recommended, free, private):**
  `tailscale funnel 8990` → gives you a trusted `https://…ts.net` URL
  reachable from your phone. (`tailscale serve 8990` for tailnet-only.)
- **Caddy on a public box:** `caddy reverse-proxy --from your.domain.com --to localhost:8990`
  — automatic Let's Encrypt.
- **ngrok for a quick test:** `ngrok http 8990` (URL changes on restart, so
  your Home-Screen install breaks each time — fine for testing, not daily use).

### 3. On the iPhone

1. Open the HTTPS URL in Safari.
2. Share → **Add to Home Screen**. Open Companion from the Home Screen.
3. Settings (⚙︎) → **Enable notifications** → Allow.

That's it. The server pushes on your schedule; the first push of each day asks
you to commit to (or skip) the day.

## Plan B: notifications without any server

iOS can't schedule web notifications locally, but the built-in **Shortcuts**
app can open Companion for you:

1. Serve `app/` anywhere static (HTTPS still recommended for Home Screen).
2. Shortcuts → Automation → **Time of Day** → e.g. every hour you care about,
   turn OFF "Ask Before Running".
3. Action: **Open URLs** → `https://your-companion-url/?from=notification`.

Opening that URL drops you straight into the daily-commitment / picker flow.
Snooze, skip-day and stop-today all work locally.

## Everyday usage notes

- **Backups:** Settings → Export downloads a JSON of everything. Import
  restores it. Deleting the PWA from the Home Screen deletes its data —
  export once in a while.
- **Into Obsidian:** every reflection detail has *Copy as Markdown*; paste it
  into your journal. Format: `### HH:MM — Energy 🟡` etc.
- **Schedule:** rhythms are presets (30 min, hourly, 2 h, 3×/day, 1×/day)
  within a daily start–end window. Missed prompts are silently replaced —
  there is never a backlog.

## Deploy with Docker

The repo ships a container setup plus a CI workflow that builds and deploys
it to your server — no multi-stage build on the server, CI scps the release
binary and files instead:

- `Dockerfile` / `docker-compose.yml` / `nginx.conf` / `entrypoint.sh` — one
  container, two processes: nginx serves the PWA on `:80` and proxies `/api/*`
  to the Rust backend on `:4000`. Server state (VAPID keys, subscription,
  schedule) lives in the `companion_state` volume — keep it; deleting it means
  re-enabling notifications on the phone.
- `.github/release-companion.yml` — on push to `main`: runs rustfmt + tests,
  builds `companion-server --release`, scps the binary, `app/` and the docker
  files to the server, then `docker compose up -d --build --force-recreate`.

**Networking:** the container publishes **no host ports** — the `ports:` block
in `docker-compose.yml` is commented out (uncomment it when running locally on
your machine for debugging). It sits on the per-app `companion_network` docker
network, same convention as the other apps on this server (e.g. `needs_network`).

The reverse proxy must be connected to that network and routes to the
container as `http://companion:80` (TLS is terminated at the proxy — iOS push
and the service worker require HTTPS). One-time setup on the server:

```sh
docker network connect companion_network <your-reverse-proxy-container>
```

Then set the proxy's upstream to `http://companion:80`.

### Building the Linux binary locally (optional)

The CI workflow does this for you; to iterate locally on a Mac:

```sh
brew install zig                                  # once: C toolchain for the musl target
rustup target add x86_64-unknown-linux-musl      # once
cargo install cargo-zigbuild                      # once: wires zig into cargo builds
cd server
cargo zigbuild --release --target x86_64-unknown-linux-musl
file target/x86_64-unknown-linux-musl/release/companion-server   # expect: statically linked
cp target/x86_64-unknown-linux-musl/release/companion-server ../companion-server
```

`cargo-zigbuild` generates the zig compiler/linker wrappers that OpenSSL's
build (vendored for the musl target, see `Cargo.toml`) needs — plain `cargo build`
can't cross-compile this crate. CI's linux-gnu build and macOS dev builds use
the system OpenSSL and are unchanged.

## Development

```sh
npm install --no-save jsdom                       # once (dev-only)
node --test --test-force-exit app/js/*.test.mjs   # schedule math + full UI click-through
cd server && cargo build                          # server
```

The UI tests boot the real `index.html` in jsdom and click through every
screen, so a broken flow fails the suite instead of your evening.

After changing any file in `app/`, bump `VERSION` in `app/sw.js` so installed
clients pick up the new files.

Read **AGENTS.md** before making changes.
