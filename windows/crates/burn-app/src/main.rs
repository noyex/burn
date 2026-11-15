//! Burn for Windows: live limits of Claude Code, Codex and Cursor in the taskbar, and what the
//! usage would cost at API prices in a panel above it.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod model;
mod panel;
#[cfg(windows)]
mod shell;
mod themes;
mod update;

use burn_core::Paths;
use model::Model;
use panel::Panel;
#[cfg(windows)]
use std::sync::Arc;
use tauri::{Emitter, Manager, WindowEvent};
use themes::Themes;

/// Appends a line to Burn's log (`%LOCALAPPDATA%\Burn\burn.log` on Windows, stderr elsewhere).
#[macro_export]
macro_rules! log {
    ($($t:tt)*) => { $crate::write_log(&format!($($t)*)) };
}

pub fn write_log(line: &str) {
    #[cfg(windows)]
    burn_taskbar::win::write_log(line);
    #[cfg(not(windows))]
    eprintln!("{line}");
}

fn main() {
    // `burn.exe --check-theme <name or path>` prints what is wrong with a theme and exits, before
    // the log, the webview or the single-instance lock: it must work while Burn runs.
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() == Some("--check-theme") {
        std::process::exit(check_theme(args.next().as_deref()));
    }
    #[cfg(windows)]
    {
        burn_taskbar::win::init_log();
        log!("Burn {} on {}", env!("CARGO_PKG_VERSION"), burn_taskbar::win::os_description());
    }
    let paths = Paths::detect();
    let themes = Themes::new(&paths);
    let model = Model::new(paths);

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // A second launch opens the panel of the running one.
            open_panel(app);
        }))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(model.clone())
        .manage(themes.clone())
        .manage(Panel::new())
        .invoke_handler(tauri::generate_handler![
            commands::get_state,
            commands::set_period,
            commands::hide_panel,
            commands::panel_visible,
            commands::set_settings,
            commands::set_launch_at_login,
            commands::quit,
            commands::shelf_copy,
            commands::share_copy,
            commands::install_update,
            commands::shelf_delete,
            commands::content_resized,
            commands::set_theme,
            commands::open_themes_folder,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            model.set_listener(Box::new(move |snap| {
                let _ = handle.emit_to(panel::LABEL, "state", snap);
                push_widget(&handle);
            }));
            // Creates the themes folder, so it can be allowed below.
            let (handle, themed) = (app.handle().clone(), model.clone());
            themes.start(move |state| {
                themed.set_theme(state.clone());
                push_alert_colors(&handle);
            });
            // Shelf previews and theme pictures are shown straight from disk, and only from there.
            let scope = app.asset_protocol_scope();
            let _ = scope.allow_directory(model.shelf_dir(), true);
            let _ = scope.allow_directory(themes.folder(), true);
            if let Some(built_in) = themes.built_in_folder() {
                let _ = scope.allow_directory(built_in, true);
            }
            #[cfg(windows)]
            {
                model.set_launch_at_login(burn_taskbar::win::autostart::is_enabled());
                shell::start(app.handle())?;
            }
            #[cfg(not(windows))]
            {
                // Development off Windows: there is no taskbar, so the panel stays open.
                app.state::<Panel>().toggle(app.handle(), None);
            }
            model.start();
            update::start(app.handle());
            // Reset countdowns in the widget age between refreshes.
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(60));
                    push_widget(&handle);
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::Focused(false) if cfg!(windows) => {
                window.app_handle().state::<Panel>().hide(window.app_handle());
            }
            WindowEvent::CloseRequested { api, .. } => {
                // Alt+F4 closes the panel, not the app.
                api.prevent_close();
                window.app_handle().state::<Panel>().hide(window.app_handle());
            }
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("build Burn")
        .run(|_app, event| {
            if let tauri::RunEvent::Exit = event {
                // On the UI thread, before the process ends: no ghost tray icon, no orphaned widget.
                #[cfg(windows)]
                burn_taskbar::win::shutdown();
            }
        });
}

fn open_panel(app: &tauri::AppHandle) {
    let panel = app.state::<Panel>();
    if panel.is_visible() {
        return;
    }
    #[cfg(windows)]
    panel.toggle(app, burn_taskbar::win::current_anchor().map(shell::placement));
    #[cfg(not(windows))]
    panel.toggle(app, None);
}

/// Runs `burn --check-theme`: the exit code, with the verdict printed where the caller can read it.
fn check_theme(argument: Option<&str>) -> i32 {
    let paths = Paths::detect();
    let dirs = burn_core::theme::ThemeDirs { user: paths.themes_dir(), built_in: burn_core::theme::built_in_dir() };
    let (code, text) = dirs.check(argument, &burn_core::theme::font_installed);
    #[cfg(windows)]
    burn_taskbar::win::console::print_line(&text);
    #[cfg(not(windows))]
    println!("{text}");
    code
}

/// Sends the widget its entries, on the UI thread that owns it.
fn push_widget(app: &tauri::AppHandle) {
    #[cfg(windows)]
    {
        let entries = app.state::<Arc<Model>>().widget_entries();
        let _ = app.run_on_main_thread(move || shell::set_entries(&entries));
    }
    #[cfg(not(windows))]
    let _ = app;
}

/// Gives the widget the theme's alert colors, on the UI thread that owns it.
fn push_alert_colors(app: &tauri::AppHandle) {
    #[cfg(windows)]
    {
        let colors = themes::alert_colors(&app.state::<Arc<Themes>>().theme());
        let _ = app.run_on_main_thread(move || shell::set_alert_colors(colors));
    }
    #[cfg(not(windows))]
    let _ = app;
}
