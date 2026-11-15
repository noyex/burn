//! What the panel's page can ask for.

use crate::model::{Model, Snapshot};
use crate::panel::Panel;
use crate::themes::Themes;
use burn_core::Period;
use burn_core::settings::Settings;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, State};

#[tauri::command]
pub fn get_state(model: State<'_, Arc<Model>>) -> Snapshot {
    model.snapshot()
}

#[tauri::command]
pub fn set_period(model: State<'_, Arc<Model>>, period: Period) {
    model.set_period(period);
}

/// The settings as the panel edited them.
#[tauri::command]
pub fn set_settings(app: AppHandle, model: State<'_, Arc<Model>>, settings: Settings) {
    #[cfg(windows)]
    {
        let tray_only = settings.tray_only;
        let _ = app.run_on_main_thread(move || burn_taskbar::win::set_tray_only(tray_only));
    }
    #[cfg(not(windows))]
    let _ = app;
    model.set_settings(settings);
}

/// Turns launch at login on or off; the panel gets the actual state back in the next snapshot.
#[tauri::command]
pub fn set_launch_at_login(model: State<'_, Arc<Model>>, on: bool) {
    #[cfg(windows)]
    {
        if let Err(e) = burn_taskbar::win::autostart::set_enabled(on) {
            crate::log!("launch at login: {e}");
        }
        model.set_launch_at_login(burn_taskbar::win::autostart::is_enabled());
    }
    #[cfg(not(windows))]
    model.set_launch_at_login(on);
}

#[tauri::command]
pub fn quit(app: AppHandle) {
    crate::log!("quit");
    app.exit(0);
}

/// Turns a theme on, or the built-in look with `None`; the panel gets the new state in a snapshot.
/// Async, so reading the folders never blocks the UI thread.
#[tauri::command]
pub async fn set_theme(themes: State<'_, Arc<Themes>>, name: Option<String>) -> Result<(), String> {
    themes.select(name.as_deref())
}

/// Shows the user's themes folder in the file manager.
#[tauri::command]
pub fn open_themes_folder(themes: State<'_, Arc<Themes>>) {
    let folder = themes.folder();
    let _ = std::fs::create_dir_all(folder);
    let opener = if cfg!(windows) {
        "explorer.exe"
    } else if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    if let Err(e) = std::process::Command::new(opener).arg(folder).spawn() {
        crate::log!("opening {}: {e}", folder.display());
    }
}

/// Puts shelf screenshots on the clipboard: one as image and file, several as files.
/// Async, so reading and converting a 4K screenshot never blocks the UI thread.
#[tauri::command]
pub async fn shelf_copy(app: AppHandle, model: State<'_, Arc<Model>>, paths: Vec<PathBuf>) -> Result<bool, ()> {
    let dir = model.shelf_dir();
    let paths: Vec<PathBuf> = paths.into_iter().filter(|p| p.parent() == Some(dir)).collect();
    #[cfg(windows)]
    {
        use burn_taskbar::win::clipboard::ImageFile;
        let single = paths.len() == 1;
        let images: Vec<ImageFile> = paths
            .iter()
            .filter_map(|p| {
                let png = std::fs::read(p).ok()?;
                let dib = if single { burn_core::shelf::png_to_dib(&png) } else { None };
                Some(ImageFile { png, dib, path: Some(p.clone()) })
            })
            .collect();
        Ok(copy_on_ui(&app, images))
    }
    #[cfg(not(windows))]
    {
        let _ = app;
        Ok(!paths.is_empty())
    }
}

/// Copies an image of `period`'s spend. False when there's nothing to share or it failed.
#[tauri::command]
pub async fn share_copy(
    app: AppHandle,
    model: State<'_, Arc<Model>>,
    themes: State<'_, Arc<Themes>>,
    period: Period,
) -> Result<bool, ()> {
    let Some(usage) = model.usage_for(period) else { return Ok(false) };
    if usage.cost <= 0.0 {
        return Ok(false);
    }
    let png = match burn_core::share::render_png(&usage, &themes.theme(), themes.theme_dir().as_deref(), 2.0) {
        Ok(png) => png,
        Err(e) => {
            crate::log!("share card failed: {e:#}");
            return Ok(false);
        }
    };
    #[cfg(windows)]
    {
        use burn_taskbar::win::clipboard::ImageFile;
        Ok(copy_on_ui(&app, vec![ImageFile { dib: burn_core::shelf::png_to_dib(&png), png, path: None }]))
    }
    #[cfg(not(windows))]
    {
        // Development off Windows: write it next to the store to look at.
        let _ = app;
        Ok(std::fs::write(model.shelf_dir().with_file_name("share.png"), png).is_ok())
    }
}

/// Writes the clipboard on the UI thread, which owns the clipboard window, and waits for it.
#[cfg(windows)]
fn copy_on_ui(app: &AppHandle, images: Vec<burn_taskbar::win::clipboard::ImageFile>) -> bool {
    if images.is_empty() {
        return false;
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let _ = app.run_on_main_thread(move || {
        let _ = tx.send(burn_taskbar::win::copy_images(&images));
    });
    rx.recv().unwrap_or(false)
}

/// Installs the newer release; Burn restarts into it.
#[tauri::command]
pub async fn install_update(app: AppHandle) {
    crate::update::install(app).await;
}

/// Deletes the given screenshots, or all of them without `paths`.
#[tauri::command]
pub fn shelf_delete(model: State<'_, Arc<Model>>, paths: Option<Vec<PathBuf>>) {
    model.delete_shelf(paths.as_deref());
}

/// Whether the panel is open; the page asks once it listens, as it may have missed `panel-shown`.
#[tauri::command]
pub fn panel_visible(panel: State<'_, Panel>) -> bool {
    panel.is_visible()
}

#[tauri::command]
pub fn hide_panel(app: AppHandle, panel: State<'_, Panel>) {
    panel.hide(&app);
}

/// The page's content size in CSS pixels; the window follows it.
#[tauri::command]
pub fn content_resized(app: AppHandle, panel: State<'_, Panel>, width: f64, height: f64) {
    if width.is_finite() && height.is_finite() && width > 0.0 && height > 0.0 {
        panel.content_resized(&app, width, height);
    }
}
