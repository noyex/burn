//! Self-update from GitHub releases, like the Mac app's Updater: checks every few hours and
//! whenever the panel opens after a while, offers the newer version in the footer, and on request
//! installs it with the per-user NSIS installer (signature checked by the updater plugin), which
//! restarts Burn.

use crate::model::Model;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};
use tauri::{AppHandle, Manager};
use tauri_plugin_updater::UpdaterExt;

/// Between successful checks, by the wall clock (a sleeping laptop doesn't count down a timer).
const CHECK_EVERY: Duration = Duration::from_secs(6 * 3600);
/// Opening the panel checks again once the last successful check is this old, so a release
/// shows up the next time the user looks instead of up to `CHECK_EVERY` later.
const CHECK_ON_OPEN_AFTER: Duration = Duration::from_secs(3600);
/// After a failed check, e.g. Burn started at login before the network was up.
const RETRY_AFTER: Duration = Duration::from_secs(30 * 60);
/// Opening the panel while offline doesn't retry more often than this.
const RETRY_ON_OPEN_AFTER: Duration = Duration::from_secs(5 * 60);
const TICK: Duration = Duration::from_secs(10 * 60);

/// The version in Cargo.toml, which only the release workflow replaces with the real one.
const UNRELEASED_VERSION: &str = "0.1.0";

struct Checks {
    succeeded_at: Option<SystemTime>,
    attempted_at: Option<SystemTime>,
}

static CHECKS: Mutex<Checks> = Mutex::new(Checks { succeeded_at: None, attempted_at: None });
static CHECKING: AtomicBool = AtomicBool::new(false);

/// Development and CI builds never update: they aren't versioned, so every release would look
/// newer.
fn enabled() -> bool {
    !cfg!(debug_assertions) && env!("CARGO_PKG_VERSION") != UNRELEASED_VERSION
}

fn older_than(t: Option<SystemTime>, age: Duration) -> bool {
    t.is_none_or(|t| t.elapsed().is_ok_and(|e| e > age))
}

/// Checks soon after launch and then every few hours.
pub fn start(app: &AppHandle) {
    if !enabled() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        // A minute in, so the first check doesn't compete with the first import.
        std::thread::sleep(Duration::from_secs(60));
        loop {
            let due = {
                let c = CHECKS.lock().unwrap_or_else(|e| e.into_inner());
                older_than(c.succeeded_at, CHECK_EVERY) && older_than(c.attempted_at, RETRY_AFTER)
            };
            if due {
                tauri::async_runtime::block_on(check(&app));
            }
            std::thread::sleep(TICK);
        }
    });
}

/// Called when the panel opens: checks in the background if the last check is getting old.
pub fn panel_opened(app: &AppHandle) {
    if !enabled() {
        return;
    }
    let due = {
        let c = CHECKS.lock().unwrap_or_else(|e| e.into_inner());
        older_than(c.succeeded_at, CHECK_ON_OPEN_AFTER) && older_than(c.attempted_at, RETRY_ON_OPEN_AFTER)
    };
    if due {
        let app = app.clone();
        tauri::async_runtime::spawn(async move { check(&app).await });
    }
}

async fn check(app: &AppHandle) {
    // The launch timer and the panel can ask at the same moment; one request is enough.
    if CHECKING.swap(true, Ordering::AcqRel) {
        return;
    }
    let ok = run_check(app).await;
    {
        let mut c = CHECKS.lock().unwrap_or_else(|e| e.into_inner());
        let now = SystemTime::now();
        c.attempted_at = Some(now);
        if ok {
            c.succeeded_at = Some(now);
        }
    }
    CHECKING.store(false, Ordering::Release);
}

async fn run_check(app: &AppHandle) -> bool {
    let model = app.state::<Arc<Model>>().inner().clone();
    let result = match app.updater() {
        Ok(u) => u.check().await,
        Err(e) => {
            crate::log!("updater unavailable: {e}");
            return false;
        }
    };
    match result {
        Ok(update) => {
            // Cleared again when the release was pulled or this copy got updated some other way.
            model.set_update(update.map(|u| u.version));
            true
        }
        Err(e) => {
            crate::log!("update check failed: {e}");
            false
        }
    }
}

/// Downloads and runs the installer. On Windows the plugin exits the process itself right after
/// starting the installer, so the widget and tray icon are removed first (`on_before_exit`).
pub async fn install(app: AppHandle) {
    let model = app.state::<Arc<Model>>().inner().clone();
    model.set_updating(true);
    let handle = app.clone();
    let result = async {
        let updater = app
            .updater_builder()
            .on_before_exit(move || {
                crate::log!("installing the update, exiting");
                cleanup_on_ui(&handle);
            })
            .build()?;
        match updater.check().await? {
            Some(u) => u.download_and_install(|_, _| {}, || {}).await.map(|_| true),
            None => Ok(false),
        }
    }
    .await;
    match result {
        // Platforms where the installer doesn't end the process.
        Ok(true) => app.restart(),
        Ok(false) => model.set_update(None),
        Err(e) => crate::log!("update failed: {e}"),
    }
    model.set_updating(false);
}

/// Removes the widget and the tray icon on the UI thread, and waits until that's done.
fn cleanup_on_ui(app: &AppHandle) {
    #[cfg(windows)]
    {
        let (tx, rx) = std::sync::mpsc::channel();
        let _ = app.run_on_main_thread(move || {
            burn_taskbar::win::shutdown();
            let _ = tx.send(());
        });
        let _ = rx.recv_timeout(Duration::from_secs(2));
    }
    #[cfg(not(windows))]
    let _ = app;
}
