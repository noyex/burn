//! Themes: the Windows counterpart of `ThemeStore.swift`. Watches the user's themes folder and
//! hands the panel a new `ThemeState` whenever what the active theme looks like changes.

use burn_core::Paths;
use burn_core::theme::{self, Loaded, ResolvedTheme, Rgba, ThemeDirs, ThemeState, Token};
use burn_taskbar::model::{AlertColors, LevelColors};
use notify::{EventKind, RecursiveMode, Watcher};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

/// The guide Burn writes into the themes folder as `README.md`.
const GUIDE: &str = include_str!("../../../../docs/themes.md");
/// Editors write a file in several steps; one reload follows the last of them.
const QUIET: Duration = Duration::from_millis(150);

/// Told whenever the active theme's state changes, from the thread that noticed.
type Apply = Box<dyn Fn(&ThemeState) + Send + Sync>;

struct Current {
    loaded: Loaded,
    state: ThemeState,
}

pub struct Themes {
    dirs: ThemeDirs,
    current: Mutex<Option<Current>>,
    /// Loads run one at a time, so an older read never lands after a newer one.
    reloading: Mutex<()>,
    apply: OnceLock<Apply>,
}

impl Themes {
    pub fn new(paths: &Paths) -> Arc<Themes> {
        Arc::new(Themes {
            dirs: ThemeDirs { user: paths.themes_dir(), built_in: theme::built_in_dir() },
            current: Mutex::new(None),
            reloading: Mutex::new(()),
            apply: OnceLock::new(),
        })
    }

    /// The user's themes folder.
    pub fn folder(&self) -> &Path {
        &self.dirs.user
    }

    /// The folder of the themes that ship with Burn, when it exists.
    pub fn built_in_folder(&self) -> Option<&Path> {
        self.dirs.built_in.as_deref()
    }

    /// The active theme; the built-in look until the first load is done.
    pub fn theme(&self) -> ResolvedTheme {
        lock(&self.current).as_ref().map_or_else(ResolvedTheme::standard, |c| c.loaded.theme.clone())
    }

    /// The folder of the active theme's file, where its pictures are.
    pub fn theme_dir(&self) -> Option<PathBuf> {
        lock(&self.current).as_ref().and_then(|c| c.loaded.theme_dir.clone())
    }

    /// Prepares the folder and the guide, then loads the themes and keeps watching the folder in
    /// the background. `apply` gets the state after every load that changed it.
    pub fn start(self: &Arc<Self>, apply: impl Fn(&ThemeState) + Send + Sync + 'static) {
        let _ = self.apply.set(Box::new(apply));
        if let Err(e) = std::fs::create_dir_all(&self.dirs.user) {
            crate::log!("themes folder {}: {e}", self.dirs.user.display());
        }
        self.dirs.write_guide(GUIDE);
        let themes = self.clone();
        let spawned = std::thread::Builder::new().name("burn-themes".into()).spawn(move || themes.watch());
        if let Err(e) = spawned {
            crate::log!("themes thread: {e}");
        }
    }

    /// Turns a theme on, or the built-in look with `None`, and applies it right away.
    pub fn select(&self, name: Option<&str>) -> Result<(), String> {
        if let Some(name) = name {
            let known = lock(&self.current).as_ref().is_some_and(|c| c.loaded.available.iter().any(|e| e.id == name));
            if !known {
                return Err(format!("no theme named \"{name}\""));
            }
        }
        self.dirs.select(name).map_err(|e| format!("couldn't save the choice: {e}"))?;
        self.reload();
        Ok(())
    }

    /// Reads the folders again; tells `apply` when the state changed.
    fn reload(&self) {
        let _one_at_a_time = lock(&self.reloading);
        let loaded = self.dirs.load(&theme::font_installed);
        let state = loaded.state(&self.dirs);
        let changed = {
            let mut current = lock(&self.current);
            let changed = current.as_ref().is_none_or(|c| c.state != state);
            *current = Some(Current { loaded, state: state.clone() });
            changed
        };
        if changed && let Some(apply) = self.apply.get() {
            apply(&state);
        }
    }

    /// Loads once, then reloads after every change in the user folder. Never returns while the
    /// watcher lives.
    fn watch(&self) {
        let (tx, rx) = mpsc::channel();
        let watcher = notify::recommended_watcher(move |event| {
            let _ = tx.send(event);
        })
        .and_then(|mut w| {
            w.watch(&self.dirs.user, RecursiveMode::NonRecursive)?;
            Ok(w)
        });
        // Fonts are scanned on the first load, which is why this runs off the UI thread.
        self.reload();
        let mut watcher = match watcher {
            Ok(w) => w,
            Err(e) => return crate::log!("watching {}: {e}", self.dirs.user.display()),
        };
        while let Ok(first) = rx.recv() {
            let mut relevant = matters(&first);
            loop {
                match rx.recv_timeout(QUIET) {
                    Ok(event) => relevant |= matters(&event),
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            // The folder was deleted or replaced: the watch died with it. Bring both back.
            if !self.dirs.user.is_dir() {
                let _ = watcher.unwatch(&self.dirs.user);
                let _ = std::fs::create_dir_all(&self.dirs.user);
                self.dirs.write_guide(GUIDE);
                if let Err(e) = watcher.watch(&self.dirs.user, RecursiveMode::NonRecursive) {
                    crate::log!("watching {} again: {e}", self.dirs.user.display());
                }
                relevant = true;
            }
            if relevant {
                self.reload();
            }
        }
    }
}

/// Whether a change of the folder can alter the look: not reads, the guide Burn writes itself, or
/// the temporary files a save goes through.
fn matters(event: &notify::Result<notify::Event>) -> bool {
    let event = match event {
        Ok(event) => event,
        Err(e) => {
            crate::log!("theme watcher: {e}");
            return false;
        }
    };
    if matches!(event.kind, EventKind::Access(_)) {
        return false;
    }
    event.paths.is_empty()
        || event.paths.iter().any(|path| {
            let name = path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
            name != "readme.md" && !name.ends_with(".tmp")
        })
}

/// The taskbar widget's alert colors from the theme's `menubar-warn` and `menubar-full`. A token
/// the theme leaves out stays `None`, which keeps the widget's own color.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn alert_colors(theme: &ResolvedTheme) -> AlertColors {
    let rgb = |c: Rgba| {
        let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
        (byte(c.r) << 16) | (byte(c.g) << 8) | byte(c.b)
    };
    let levels = |dark| LevelColors {
        warn: theme.color(Token::MenuBarWarn, dark).map(rgb),
        full: theme.color(Token::MenuBarFull, dark).map(rgb),
    };
    AlertColors { light: levels(false), dark: levels(true) }
}

/// A poisoned lock only means another thread panicked mid-update; the data is still usable.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alert_colors_follow_the_theme_per_appearance() {
        assert_eq!(alert_colors(&ResolvedTheme::standard()), AlertColors::default());
        let (theme, issues) = ResolvedTheme::parse(
            br##"{"colors": {"menubar-warn": "#112233"}, "dark": {"menubar-full": "#AABBCC"}}"##,
            "t",
            &|_| true,
            &|_| true,
        );
        assert!(issues.is_empty(), "{issues:?}");
        let colors = alert_colors(&theme);
        assert_eq!(colors.light, LevelColors { warn: Some(0x112233), full: None });
        assert_eq!(colors.dark, LevelColors { warn: Some(0x112233), full: Some(0xAABBCC) });
    }

    #[test]
    fn only_real_theme_changes_matter() {
        use notify::event::{AccessKind, CreateKind};
        let change = |kind, name: &str| Ok(notify::Event::new(kind).add_path(PathBuf::from("themes").join(name)));
        assert!(matters(&change(EventKind::Create(CreateKind::File), "a.json")));
        assert!(matters(&change(EventKind::Create(CreateKind::File), "active.txt")));
        assert!(!matters(&change(EventKind::Create(CreateKind::File), "README.md")));
        assert!(!matters(&change(EventKind::Create(CreateKind::File), "active.txt.tmp")));
        assert!(!matters(&change(EventKind::Access(AccessKind::Any), "a.json")));
    }
}
