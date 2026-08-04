//! Companion push server — the smallest thing that can wake up an iPhone.
//!
//! Responsibilities (nothing more):
//!   1. Serve the static PWA from ../app (same origin = no CORS pain).
//!   2. Store the user's push subscription(s) and notification schedule.
//!   3. Every 30s, check if a notification slot is due and send Web Push.
//!
//! Reflection content NEVER reaches this server — it lives in the browser.
//! Single user, single JSON state file, no database. KISS.

use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{FixedOffset, Timelike, Utc};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower_http::cors::CorsLayer;
use tower_http::services::{ServeDir, ServeFile};
use web_push::{
    ContentEncoding, HyperWebPushClient, SubscriptionInfo, VapidSignatureBuilder, WebPushClient,
    WebPushMessageBuilder,
};

const STATE_FILE: &str = "companion-state.json";
const TICK_SECONDS: u64 = 30;
const PUSH_TIMEOUT_SECS: u64 = 10;

// ─────────────────────────── state ───────────────────────────

/// Everything the server knows, persisted as one JSON file.
#[derive(Serialize, Deserialize, Default)]
struct AppState {
    vapid_public: String,
    vapid_private: String,
    /// VAPID `sub` claim (mailto: or https: URI). Apple rejects JWTs without it.
    vapid_subject: String,
    subscriptions: Vec<SubscriptionInfo>,
    schedule: Schedule,
    day: DayState,
    /// Last slot we pushed for, as (date "YYYY-MM-DD", minutes-since-midnight).
    last_sent: Option<(String, u32)>,
}

/// Mirrors the client's settings. Times are minutes since local midnight.
#[derive(Serialize, Deserialize, Clone)]
struct Schedule {
    start_min: u32,
    end_min: u32,
    /// One of: "30min" | "hourly" | "2h" | "3x" | "1x" — keep in sync with app/js/schedule.js
    rhythm: String,
    snooze_min: u32,
    /// The user's UTC offset in minutes (e.g. Vienna summer = 120).
    tz_offset_min: i32,
}

impl Default for Schedule {
    fn default() -> Self {
        Self {
            start_min: 9 * 60,
            end_min: 18 * 60,
            rhythm: "hourly".into(),
            snooze_min: 10,
            tz_offset_min: 0,
        }
    }
}

/// Per-day flags, reset automatically when the date changes.
#[derive(Serialize, Deserialize, Clone, Default)]
struct DayState {
    date: String, // local "YYYY-MM-DD"
    committed: bool,
    skipped: bool,
    stopped: bool,
    /// If set, send one notification at this UTC epoch-second, then clear.
    snooze_until_epoch: Option<i64>,
    /// Today-only overrides from the commitment screen (None = use schedule).
    end_min: Option<u32>,
    rhythm: Option<String>,
}

type Shared = Arc<Mutex<AppState>>;

fn load_state() -> AppState {
    std::fs::read_to_string(STATE_FILE)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_state(state: &AppState) {
    // Write-then-rename would be more robust; for a single-user toy server a
    // straight write is acceptable and simpler.
    if let Ok(json) = serde_json::to_string_pretty(state) {
        let _ = std::fs::write(STATE_FILE, json);
    }
}

/// Generate a VAPID keypair (P-256) on first run so the user never has to.
fn ensure_vapid(state: &mut AppState) {
    if !state.vapid_public.is_empty() {
        return;
    }
    let secret = p256::SecretKey::random(&mut rand_core::OsRng);
    let public = secret.public_key();
    state.vapid_private = URL_SAFE_NO_PAD.encode(secret.to_bytes());
    // Browsers expect the uncompressed SEC1 point (65 bytes, 0x04-prefixed).
    state.vapid_public = URL_SAFE_NO_PAD.encode(public.to_encoded_point(false).as_bytes());
    println!("Generated new VAPID keypair (stored in {STATE_FILE}).");
}

/// The VAPID `sub` claim — a mailto: or https: contact URI. Apple's push
/// service (web.push.apple.com) rejects any VAPID JWT without a sub claim with
/// 400 BadJwtToken; Chrome/FCM is lenient, which is why this only bites on iOS.
/// Read once at startup; override with POCKET_VAPID_SUBJECT.
fn vapid_subject() -> String {
    std::env::var("POCKET_VAPID_SUBJECT").unwrap_or_else(|_| "mailto:pocket@localhost".to_string())
}

/// Persist the subject so /api/status can show it (never secrets, only this).
fn ensure_vapid_subject(state: &mut AppState) {
    if state.vapid_subject.is_empty() {
        state.vapid_subject = vapid_subject();
    }
}

// ─────────────────────────── schedule math ───────────────────────────
// Mirror of app/js/schedule.js — keep both in sync (see AGENTS.md).

fn slot_times(start: u32, end: u32, rhythm: &str) -> Vec<u32> {
    if end <= start {
        return vec![start];
    }
    let interval = |step: u32| (start..=end).step_by(step as usize).collect::<Vec<_>>();
    match rhythm {
        "30min" => interval(30),
        "hourly" => interval(60),
        "2h" => interval(120),
        "3x" => vec![start, start + (end - start) / 2, end],
        "1x" => vec![start],
        _ => interval(60),
    }
}

// ─────────────────────────── push sending ───────────────────────────

/// Sends a push to every subscription. Returns one (endpoint, result) pair per
/// subscription so callers (e.g. /api/test-push) can surface failures instead
/// of only logging. Dead subscriptions are pruned: 404/410 always, and 403
/// (Apple: subscription no longer valid, e.g. after a PWA reinstall) only
/// when another subscription in this batch succeeded — so a global
/// authorization failure can never wipe the live subscription.
async fn send_push(
    state: &mut AppState,
    title: &str,
    body: &str,
    first: bool,
) -> Vec<(String, Result<(), String>)> {
    let payload = serde_json::json!({ "title": title, "body": body, "first": first }).to_string();
    let client = HyperWebPushClient::new();
    let mut results: Vec<(String, Result<(), String>)> = Vec::new();
    let mut dead: Vec<String> = Vec::new(); // 404/410 — always dead
    let mut maybe_dead: Vec<String> = Vec::new(); // 403 — dead only if others succeeded
    for sub in &state.subscriptions {
        let result = async {
            let mut sig_builder = VapidSignatureBuilder::from_base64(
                &state.vapid_private,
                web_push::URL_SAFE_NO_PAD,
                sub,
            )?;
            // Apple requires the sub claim (mailto: or https:) — Chrome doesn't,
            // which is why this looks fine on desktop and dies on the iPhone.
            // add_claim takes &mut self, so the one-liner chain has to be split.
            sig_builder.add_claim("sub", state.vapid_subject.as_str());
            let sig = sig_builder.build()?;
            let mut msg = WebPushMessageBuilder::new(sub);
            msg.set_vapid_signature(sig);
            msg.set_payload(ContentEncoding::Aes128Gcm, payload.as_bytes());
            let message = msg.build()?;
            // Bound every request: the web-push hyper client has no timeout of
            // its own, and the state lock is held across this send — a stuck
            // connection would wedge the whole server (status/schedule/day/tick
            // all block on the mutex). 10s per subscription is plenty for Apple.
            tokio::time::timeout(
                std::time::Duration::from_secs(PUSH_TIMEOUT_SECS),
                client.send(message),
            )
            .await
            .map_err(|_| web_push::WebPushError::Other("timeout".to_string()))?
        }
        .await;
        let endpoint = sub.endpoint.clone();
        match result {
            Ok(()) => results.push((endpoint, Ok(()))),
            Err(e) => {
                // Debug repr carries the HTTP status (e.g. BadJwtToken).
                eprintln!("push to {} failed: {e:?}", sub.endpoint);
                // Unspecified is the crate's opaque transport error (hyper::Error
                // → Unspecified): the request never completed — DNS, firewall,
                // TLS handshake or a dropped connection to the push host. It is
                // NOT a VAPID/HTTP-status problem; those surface as BadRequest /
                // Unauthorized / EndpointNotFound etc. instead.
                if matches!(e, web_push::WebPushError::Unspecified) {
                    eprintln!(
                        "  hint: transport failure talking to the push endpoint — \
                         check egress/TLS from this server (try: curl -sI https://web.push.apple.com)"
                    );
                }
                results.push((endpoint.clone(), Err(format!("{e:?}"))));
                // 404/410 mean the subscription is gone — forget it.
                if matches!(
                    e,
                    web_push::WebPushError::EndpointNotValid
                        | web_push::WebPushError::EndpointNotFound
                ) {
                    dead.push(endpoint);
                } else if matches!(
                    e,
                    web_push::WebPushError::Other(ref s) if s.as_str() == "403"
                ) {
                    // Apple 403 = this endpoint is no longer valid (e.g. the PWA
                    // was deleted/reinstalled) — but only prune if we're sure it's
                    // endpoint-specific and not a global authorization problem.
                    maybe_dead.push(endpoint);
                } else if matches!(
                    e,
                    web_push::WebPushError::Other(ref s) if s.as_str() == "timeout"
                ) {
                    eprintln!(
                        "  hint: push endpoint did not answer within {PUSH_TIMEOUT_SECS}s — \
                         Apple may be throttling this server after repeated invalid requests; \
                         dead subscriptions are pruned automatically"
                    );
                }
            }
        }
    }
    if results.iter().any(|(_, r)| r.is_ok()) {
        dead.extend(maybe_dead);
    }
    state.subscriptions.retain(|s| !dead.contains(&s.endpoint));
    results
}

/// Runs every TICK_SECONDS. Decides whether a notification is due.
async fn tick(shared: &Shared) {
    let mut state = shared.lock().await;
    if state.subscriptions.is_empty() {
        return;
    }

    let offset = FixedOffset::east_opt(state.schedule.tz_offset_min * 60)
        .unwrap_or_else(|| FixedOffset::east_opt(0).unwrap());
    let now_local = Utc::now().with_timezone(&offset);
    let today = now_local.format("%Y-%m-%d").to_string();
    let now_min = now_local.hour() * 60 + now_local.minute();

    // New day → reset day flags.
    if state.day.date != today {
        state.day = DayState {
            date: today.clone(),
            ..Default::default()
        };
        save_state(&state);
    }

    // Snooze fires exactly once, regardless of other flags except skip/stop.
    if let Some(when) = state.day.snooze_until_epoch {
        if Utc::now().timestamp() >= when && !state.day.skipped && !state.day.stopped {
            state.day.snooze_until_epoch = None;
            send_push(
                &mut state,
                "Snooze is over",
                "Ready for that check-in now?",
                false,
            )
            .await;
            save_state(&state);
        }
        return; // while snoozing, regular slots stay silent
    }

    if state.day.skipped || state.day.stopped {
        return;
    }

    let start = state.schedule.start_min;
    let end = state.day.end_min.unwrap_or(state.schedule.end_min);
    let rhythm = state
        .day
        .rhythm
        .clone()
        .unwrap_or_else(|| state.schedule.rhythm.clone());
    let slots = slot_times(start, end, &rhythm);

    // The latest slot that is already due. Missed slots are silently replaced —
    // we only ever notify for the most recent one (no guilt backlog).
    let Some(&due) = slots.iter().filter(|&&s| s <= now_min).last() else {
        return;
    };
    if state.last_sent.as_ref() == Some(&(today.clone(), due)) {
        return; // already sent this slot
    }

    let first = !state.day.committed;
    let (title, body) = if first {
        (
            "Good morning — reflect today?",
            "Confirm today's rhythm, or skip the day. No pressure.",
        )
    } else {
        (
            "Time for a check-in",
            "A quiet minute with yourself. Pick a reflection — or snooze.",
        )
    };
    send_push(&mut state, title, body, first).await;
    state.last_sent = Some((today, due));
    save_state(&state);
}

// ─────────────────────────── http api ───────────────────────────

async fn get_vapid(State(shared): State<Shared>) -> Json<serde_json::Value> {
    let state = shared.lock().await;
    Json(serde_json::json!({ "key": state.vapid_public }))
}

#[derive(Deserialize)]
struct SubscribeBody {
    subscription: SubscriptionInfo,
}

async fn post_subscribe(
    State(shared): State<Shared>,
    Json(body): Json<SubscribeBody>,
) -> StatusCode {
    let mut state = shared.lock().await;
    state
        .subscriptions
        .retain(|s| s.endpoint != body.subscription.endpoint);
    state.subscriptions.push(body.subscription);
    save_state(&state);
    StatusCode::NO_CONTENT
}

async fn post_schedule(State(shared): State<Shared>, Json(s): Json<Schedule>) -> StatusCode {
    let mut state = shared.lock().await;
    state.schedule = s;
    save_state(&state);
    StatusCode::NO_CONTENT
}

/// Day actions from the client / notification buttons.
/// {action:"commit", end_min?, rhythm?} | {action:"skip"} | {action:"stop"} | {action:"snooze"}
#[derive(Deserialize)]
struct DayBody {
    action: String,
    end_min: Option<u32>,
    rhythm: Option<String>,
}

async fn post_day(State(shared): State<Shared>, Json(body): Json<DayBody>) -> StatusCode {
    let mut state = shared.lock().await;
    match body.action.as_str() {
        "commit" => {
            state.day.committed = true;
            state.day.end_min = body.end_min;
            state.day.rhythm = body.rhythm;
        }
        "skip" => state.day.skipped = true,
        "stop" => state.day.stopped = true,
        "snooze" => {
            let mins = state.schedule.snooze_min as i64;
            state.day.snooze_until_epoch = Some(Utc::now().timestamp() + mins * 60);
        }
        _ => return StatusCode::BAD_REQUEST,
    }
    save_state(&state);
    StatusCode::NO_CONTENT
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "ok": true }))
}

/// Debuggability endpoint: what the server knows, without secrets. Never
/// includes vapid_private.
///
/// { "subscriptions": 1, "vapid_subject": "mailto:…", "schedule": {…},
///   "day": {…}, "last_sent": ["2026-08-04", 660], "server_local_time": "13:05" }
async fn get_status(State(shared): State<Shared>) -> Json<serde_json::Value> {
    let state = shared.lock().await;
    let offset = FixedOffset::east_opt(state.schedule.tz_offset_min * 60)
        .unwrap_or_else(|| FixedOffset::east_opt(0).unwrap());
    Json(serde_json::json!({
        "subscriptions": state.subscriptions.len(),
        "vapid_subject": state.vapid_subject,
        "schedule": state.schedule,
        "day": state.day,
        "last_sent": state.last_sent,
        "server_local_time": Utc::now().with_timezone(&offset).format("%H:%M").to_string(),
    }))
}

/// Fire a push right now, bypassing all schedule/day logic. Returns the
/// per-subscription results in the body so failures are visible in curl output
/// and in the app, not just in server logs.
async fn post_test_push(State(shared): State<Shared>) -> Json<serde_json::Value> {
    let mut state = shared.lock().await;
    let results = send_push(
        &mut state,
        "Test notification",
        "Companion push works — this phone can be reached.",
        false,
    )
    .await;
    save_state(&state); // persist any dead-subscription pruning
    let results = results
        .into_iter()
        .map(|(endpoint, r)| match r {
            Ok(()) => serde_json::json!({ "endpoint": endpoint, "ok": true }),
            Err(e) => serde_json::json!({ "endpoint": endpoint, "ok": false, "error": e }),
        })
        .collect::<Vec<_>>();
    Json(serde_json::json!({ "sent_to": results.len(), "results": results }))
}

// ─────────────────────────── main ───────────────────────────

#[tokio::main]
async fn main() {
    let mut initial = load_state();
    ensure_vapid(&mut initial);
    ensure_vapid_subject(&mut initial);
    save_state(&initial);
    let shared: Shared = Arc::new(Mutex::new(initial));

    // Background notification loop.
    let ticker_state = shared.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(TICK_SECONDS));
        loop {
            interval.tick().await;
            tick(&ticker_state).await;
        }
    });

    // Static app dir: ./app when run from repo root, ../app when run from server/.
    let app_dir = ["app", "../app"]
        .iter()
        .map(PathBuf::from)
        .find(|p| p.join("index.html").exists())
        .expect("could not find the app/ directory — run from the repo root or server/");

    let router = Router::new()
        .route("/api/health", get(health))
        .route("/api/status", get(get_status))
        .route("/api/test-push", post(post_test_push))
        .route("/api/vapid-public-key", get(get_vapid))
        .route("/api/subscribe", post(post_subscribe))
        .route("/api/schedule", post(post_schedule))
        .route("/api/day", post(post_day))
        .fallback_service(
            ServeDir::new(&app_dir).fallback(ServeFile::new(app_dir.join("index.html"))),
        )
        .layer(CorsLayer::permissive()) // harmless same-origin; helps if app is hosted elsewhere
        .with_state(shared);

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8990);
    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    println!(
        "Companion server on http://{addr} (serving {})",
        app_dir.display()
    );
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind failed");
    axum::serve(listener, router).await.expect("server crashed");
}
