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

/// Default VAPID `sub` — a mailto: or https: contact URI. Apple's push
/// service rejects any VAPID JWT without a sub claim, and it also rejects
/// mailto: subjects whose domain it won't accept (e.g. `@localhost` →
/// 403 BadJwtToken — verified against web.push.apple.com, Aug 2026).
/// Chrome/FCM is lenient, which is why this only bites on iOS.
fn default_vapid_subject() -> &'static str {
    "https://github.com/heartlabs/prompt-yourself"
}

/// Resolve the subject to send: the env var always wins on restart (so a
/// deploy can fix a bad value already persisted in the state file), then
/// whatever is stored, then the default. Persisted so /api/status can show
/// it (never secrets, only this).
fn ensure_vapid_subject(state: &mut AppState) {
    if let Ok(sub) = std::env::var("POCKET_VAPID_SUBJECT") {
        state.vapid_subject = sub;
    } else if state.vapid_subject.is_empty() {
        state.vapid_subject = default_vapid_subject().to_string();
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

/// What a single push attempt produced, with enough fidelity to tell "the
/// endpoint is dead" (prune it) from "our request was rejected" (fix the
/// server) from "Apple didn't answer" (transient).
enum PushOutcome {
    Ok,
    /// The push host did not answer within PUSH_TIMEOUT_SECS. Transient —
    /// Apple throttles servers that send repeated invalid requests. NEVER prune.
    TimedOut,
    /// Build or send failed; web-push 0.11 errors carry the push host's
    /// response body when it sent one (e.g.
    /// Other(ErrorInfo{message: "{\"reason\":\"BadJwtToken\"}"})).
    Failed(web_push::WebPushError),
}

/// Decide whether a failed push means the subscription is dead and should be
/// pruned. 404/410 always. Apple 403 with a JWT/VAPID reason (BadJwtToken,
/// VapidPkHashMismatch, VapidTimestampInvalid) means OUR request is wrong —
/// the subscription is fine, keep it. Any other 403 (Unregistered,
/// BadDeviceToken) is a dead endpoint.
fn should_prune(status: Option<u16>, reason: &str) -> bool {
    match status {
        Some(404) | Some(410) => true,
        Some(403) => {
            let r = reason.to_ascii_lowercase();
            !(r.contains("jwt") || r.contains("vapid"))
        }
        _ => false,
    }
}

/// Reduce a web-push error to (HTTP status, reason body) for the prune
/// decision. web-push 0.11 keeps the host's body in ErrorInfo::message — for
/// Apple's {"reason":"..."} bodies that's the raw JSON. Transport errors
/// (Unspecified) have no status.
fn status_and_reason(e: &web_push::WebPushError) -> (Option<u16>, String) {
    match e {
        web_push::WebPushError::Unauthorized(info) => (Some(401), info.message.clone()),
        web_push::WebPushError::BadRequest(info) => (Some(400), info.message.clone()),
        web_push::WebPushError::EndpointNotValid(info) => (Some(410), info.message.clone()),
        web_push::WebPushError::EndpointNotFound(info) => (Some(404), info.message.clone()),
        web_push::WebPushError::ServerError { info, .. } => (Some(500), info.message.clone()),
        web_push::WebPushError::Other(info) => (Some(info.code), info.message.clone()),
        _ => (None, String::new()),
    }
}

/// Sends a push to every subscription. Returns one (endpoint, result) pair per
/// subscription so callers (e.g. /api/test-push) can surface failures instead
/// of only logging. Result strings carry the push host's reason body when it
/// sent one — the info that used to hide behind Other("403").
async fn send_push(
    state: &mut AppState,
    title: &str,
    body: &str,
    first: bool,
) -> Vec<(String, Result<(), String>)> {
    let payload = serde_json::json!({ "title": title, "body": body, "first": first }).to_string();
    let client = HyperWebPushClient::new();
    let mut results: Vec<(String, Result<(), String>)> = Vec::new();
    let mut dead: Vec<String> = Vec::new();
    for sub in &state.subscriptions {
        let message = async {
            let mut sig_builder = VapidSignatureBuilder::from_base64(&state.vapid_private, sub)?;
            // Apple requires a VALID sub claim (https: or mailto: with a real
            // domain — `mailto:...@localhost` → 403 BadJwtToken; Chrome doesn't
            // care, which is why this looks fine on desktop and dies on iOS).
            // add_claim takes &mut self, so the one-liner chain has to be split.
            sig_builder.add_claim("sub", state.vapid_subject.as_str());
            let sig = sig_builder.build()?;
            let mut msg = WebPushMessageBuilder::new(sub);
            msg.set_vapid_signature(sig);
            msg.set_payload(ContentEncoding::Aes128Gcm, payload.as_bytes());
            msg.build()
        }
        .await;

        let outcome = match message {
            Err(e) => PushOutcome::Failed(e),
            Ok(message) => {
                // Bound every request: the state lock is held across this send
                // (status/schedule/day/tick all block on the mutex), so a stuck
                // connection would wedge the whole server. 10s per subscription
                // is plenty for Apple.
                match tokio::time::timeout(
                    std::time::Duration::from_secs(PUSH_TIMEOUT_SECS),
                    client.send(message),
                )
                .await
                {
                    Err(_) => PushOutcome::TimedOut,
                    Ok(Ok(())) => PushOutcome::Ok,
                    Ok(Err(e)) => PushOutcome::Failed(e),
                }
            }
        };

        let endpoint = sub.endpoint.clone();
        match outcome {
            PushOutcome::Ok => results.push((endpoint, Ok(()))),
            PushOutcome::TimedOut => {
                eprintln!(
                    "push to {} timed out after {PUSH_TIMEOUT_SECS}s — Apple may be \
                     throttling this server after repeated invalid requests",
                    sub.endpoint
                );
                results.push((endpoint, Err("timeout".into())));
            }
            PushOutcome::Failed(e) => {
                // Display carries the reason body when the host sent one, e.g.
                // "other: code 403, errno 999: unknown error ({\"reason\":\"BadJwtToken\"})"
                // — the detail /api/test-push used to hide behind Other("403").
                eprintln!("push to {} failed: {e}", sub.endpoint);
                if matches!(&e, web_push::WebPushError::Unspecified) {
                    eprintln!(
                        "  hint: transport failure talking to the push endpoint — \
                         check egress/TLS from this server (try: curl -sI https://web.push.apple.com)"
                    );
                }
                let (status, reason) = status_and_reason(&e);
                if should_prune(status, &reason) {
                    if status == Some(403) {
                        eprintln!(
                            "  hint: Apple 403 — endpoint is dead (PWA deleted/reinstalled, \
                             or unsubscribed). Pruning; the phone re-registers on next launch."
                        );
                    }
                    dead.push(endpoint.clone());
                } else if status == Some(403) {
                    eprintln!(
                        "  hint: Apple 403 with a JWT/VAPID reason — the subscription is fine, \
                         OUR request is being rejected. Check POCKET_VAPID_SUBJECT (a \
                         mailto:...@localhost subject → BadJwtToken), the VAPID keypair, and \
                         the server clock. NOT pruning."
                    );
                }
                results.push((endpoint, Err(format!("{e}"))));
            }
        }
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

#[cfg(test)]
mod tests {
    use http::StatusCode;

    /// Apple's web push error body is {"reason":"..."} — web-push 0.11 can't
    /// map it onto ErrorInfo's fields, but its fallback keeps the RAW body in
    /// `message`. This is what makes 403 BadJwtToken debuggable. Guard it so a
    /// crate bump can't silently lose the reason again.
    #[test]
    fn apple_403_reason_is_preserved() {
        let err = web_push::request_builder::parse_response(
            StatusCode::FORBIDDEN,
            br#"{"reason":"BadJwtToken"}"#.to_vec(),
        )
        .unwrap_err();
        match &err {
            web_push::WebPushError::Other(info) => {
                assert_eq!(info.code, 403);
                assert!(
                    info.message.contains("BadJwtToken"),
                    "reason body must survive: {info:?}"
                );
            }
            other => panic!("expected Other(ErrorInfo), got {other:?}"),
        }
        // …and it must survive the status/reason reduction used by send_push.
        let (status, reason) = super::status_and_reason(&err);
        assert_eq!(status, Some(403));
        assert!(reason.contains("BadJwtToken"));
    }

    /// The prune/keep decision must tell "our request is rejected" (JWT/VAPID
    /// reason — subscription is fine, keep it) from "the endpoint is dead"
    /// (prune it). This is what used to be a blanket "403 → prune", which
    /// deleted healthy subscriptions whenever Apple rejected our JWT.
    #[test]
    fn jwt_403_is_not_pruned_but_dead_endpoints_are() {
        use super::should_prune;
        // Apple 403 with a JWT/VAPID reason: OUR bug, keep the subscription.
        assert!(!should_prune(Some(403), "{\"reason\":\"BadJwtToken\"}"));
        assert!(!should_prune(
            Some(403),
            "{\"reason\":\"VapidPkHashMismatch\"}"
        ));
        assert!(!should_prune(
            Some(403),
            "{\"reason\":\"VapidTimestampInvalid\"}"
        ));
        // Dead endpoints: prune.
        assert!(should_prune(Some(403), "{\"reason\":\"Unregistered\"}"));
        assert!(should_prune(Some(403), "{\"reason\":\"BadDeviceToken\"}"));
        assert!(should_prune(Some(403), "")); // no reason → assume dead
        assert!(should_prune(Some(404), ""));
        assert!(should_prune(Some(410), ""));
        // Transient: never prune.
        assert!(!should_prune(Some(429), "throttled"));
        assert!(!should_prune(Some(500), ""));
        assert!(!should_prune(None, "")); // transport / timeout
    }
}
