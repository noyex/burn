//! Self-update from GitHub releases, like the Mac app's Updater: checks once a day, offers the
//! newer version in the footer, and on request installs it with the per-user NSIS installer
//! (signature checked by the updater plugin), which restarts Burn.

use crate::model::Model;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tauri::{AppHandle, Manager};
use tauri_plugin_updater::UpdaterExt;

/// Between successful checks, by the wall clock (a sleeping laptop doesn't count down a timer).
const CHECK_EVERY: Duration = Duration::from_secs(24 * 3600);
/// After a failed check, e.g. Burn started at login before the network was up.
const RETRY_AFTER: Duration = Duration::from_secs(30 * 60);
const TICK: Duration = Duration::from_secs(10 * 60);

/// The version in Cargo.toml, which only the release workflow replaces with the real one.
const UNRELEASED_VERSION: &str = "0.1.0";

/// Checks soon after launch and then once a day. Development and CI builds never update: they
/// aren't versioned, so every release would look newer.
pub fn start(app: &AppHandle) {
    if cfg!(debug_assertions) || env!("CARGO_PKG_VERSION") == UNRELEASED_VERSION {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        // A minute in, so the first check doesn't compete with the first import.
        std::thread::sleep(Duration::from_secs(60));
        let mut next = SystemTime::now();
        loop {
            if SystemTime::now() >= next {
                let ok = tauri::async_runtime::block_on(check(&app));
                next = SystemTime::now() + if ok { CHECK_EVERY } else { RETRY_AFTER };
            }
            std::thread::sleep(TICK);
        }
    });
}

async fn check(app: &AppHandle) -> bool {
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
