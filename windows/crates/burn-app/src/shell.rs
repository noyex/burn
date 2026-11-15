//! Wires the native taskbar widget and tray icon (burn-taskbar) to the app.

use crate::model::{Model, WidgetEntry};
use crate::panel::{Panel, Placement};
use burn_core::ProviderId;
use burn_taskbar::model::{Entry, Provider};
use burn_taskbar::win::clipboard::ClipboardImage;
use burn_taskbar::win::{self, Anchor, Host};
use std::rc::Rc;
use std::sync::Arc;
use tauri::{AppHandle, Manager};

struct TauriHost {
    app: AppHandle,
}

impl Host for TauriHost {
    fn activate(&self, anchor: Option<Anchor>) {
        self.app.state::<Panel>().toggle(&self.app, anchor.map(placement));
    }

    fn menu_opened(&self) {
        self.app.state::<Panel>().hide(&self.app);
    }

    fn open_log(&self) {
        // Opens the log in the default text editor.
        let _ = std::process::Command::new("explorer.exe").arg(win::log_path()).spawn();
    }

    fn clipboard_image(&self, image: ClipboardImage) {
        let model = self.app.state::<Arc<Model>>().inner().clone();
        // Converting and saving a 4K screenshot takes a moment: off the UI thread.
        std::thread::spawn(move || {
            let png = match image {
                ClipboardImage::Png(png) => png,
                ClipboardImage::Dib(dib) => match burn_core::shelf::dib_to_png(&dib) {
                    Some(png) => png,
                    None => return crate::log!("copied image in an unsupported bitmap format"),
                },
            };
            model.capture(&png);
        });
    }

    fn quit(&self) {
        crate::log!("quit");
        self.app.exit(0);
    }
}

pub fn placement(a: Anchor) -> Placement {
    Placement { anchor: a.rect, edge: a.edge, work: a.work, scale: f64::from(a.dpi.max(96)) / 96.0 }
}

/// Creates the widget (or the tray icon). Runs on the main thread, inside Tauri's setup.
pub fn start(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let model = app.state::<Arc<Model>>();
    let tray_only = model.snapshot().settings.tray_only;
    let entries = to_entries(&model.widget_entries());
    win::start(Rc::new(TauriHost { app: app.clone() }), entries, tray_only)?;
    Ok(())
}

pub fn set_entries(entries: &[WidgetEntry]) {
    win::set_entries(to_entries(entries));
}

fn to_entries(entries: &[WidgetEntry]) -> Vec<Entry> {
    let now = chrono::Utc::now().timestamp_millis();
    entries
        .iter()
        .map(|e| Entry {
            provider: match e.provider {
                ProviderId::Claude => Provider::Claude,
                ProviderId::Codex => Provider::Codex,
                ProviderId::Cursor => Provider::Cursor,
            },
            used: e.used,
            logo: e.logo,
            resets_in: e.resets_at.map(|t| ((t - now).max(0) / 1000) as u64),
        })
        .collect()
}
