//! Milestone 1 spike: Burn's widget embedded in the Windows taskbar, with demo data, plus a
//! tray icon fallback and a placeholder panel that opens away from the taskbar.
#![cfg_attr(windows, windows_subsystem = "windows")]
// Off Windows only the shared modules build, for their tests.
#![cfg_attr(not(windows), allow(dead_code))]

mod layout;
mod model;
#[cfg(windows)]
mod win;

fn main() {
    #[cfg(windows)]
    win::run();
    #[cfg(not(windows))]
    eprintln!("burn-spike only runs on Windows. `cargo test` covers the shared layout code.");
}
