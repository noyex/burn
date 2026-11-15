//! Where Burn reads provider data and keeps its own files.
//!
//! Everything goes through a `Paths` value so tests can point it at a fixture home.
//! Env overrides: `BURN_HOME` (the user's home), `BURN_DATA_DIR` (Burn's own files), `BURN_DB`.

use std::env;
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Paths {
    /// `%USERPROFILE%` on Windows, `$HOME` elsewhere. Holds `.claude`, `.codex`, `.t3`.
    pub home: PathBuf,
    /// Burn's own files: `%LOCALAPPDATA%\Burn` on Windows.
    pub data_dir: PathBuf,
    /// Roaming app data (`%APPDATA%`), where Cursor keeps its state. macOS: `~/Library/Application Support`.
    pub app_data: PathBuf,
    db: Option<PathBuf>,
}

impl Paths {
    /// Real locations for this user, with env overrides.
    pub fn detect() -> Paths {
        let home = env::var_os("BURN_HOME").map(PathBuf::from).unwrap_or_else(default_home);
        let app_data =
            if env::var_os("BURN_HOME").is_some() { default_app_data_in(&home) } else { default_app_data(&home) };
        let data_dir = match (env::var_os("BURN_DATA_DIR"), env::var_os("BURN_HOME")) {
            (Some(dir), _) => PathBuf::from(dir),
            // A redirected home (fixtures) must never write into the real store.
            (None, Some(_)) => home.join(".burn-dev"),
            (None, None) => default_data_dir(&home),
        };
        Paths { home, data_dir, app_data, db: env::var_os("BURN_DB").map(PathBuf::from) }
    }

    /// Everything below one fixture home; Burn's files in `data_dir`.
    pub fn with_home(home: impl Into<PathBuf>, data_dir: impl Into<PathBuf>) -> Paths {
        let home = home.into();
        Paths { app_data: default_app_data_in(&home), home, data_dir: data_dir.into(), db: None }
    }

    pub fn db_path(&self) -> PathBuf {
        self.db.clone().unwrap_or_else(|| self.data_dir.join("usage.sqlite"))
    }

    /// Burn's 24 h copy of the LiteLLM rate table.
    pub fn rates_cache(&self) -> PathBuf {
        self.data_dir.join("model-rates.json")
    }

    /// The user's themes folder: `<name>.json` themes, `active.txt` and the guide.
    pub fn themes_dir(&self) -> PathBuf {
        self.data_dir.join("themes")
    }

    pub fn claude_projects(&self) -> PathBuf {
        self.home.join(".claude").join("projects")
    }

    /// Claude Code's OAuth credentials file (Windows and Linux; macOS uses the Keychain).
    pub fn claude_credentials(&self) -> PathBuf {
        self.home.join(".claude").join(".credentials.json")
    }

    pub fn codex_home(&self) -> PathBuf {
        self.home.join(".codex")
    }

    pub fn codex_sessions(&self) -> PathBuf {
        self.codex_home().join("sessions")
    }

    pub fn t3_userdata(&self) -> PathBuf {
        self.home.join(".t3").join("userdata")
    }

    pub fn cursor_state_db(&self) -> PathBuf {
        self.app_data.join("Cursor").join("User").join("globalStorage").join("state.vscdb")
    }
}

fn default_home() -> PathBuf {
    #[cfg(windows)]
    if let Some(p) = env::var_os("USERPROFILE") {
        return PathBuf::from(p);
    }
    env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(windows)]
fn default_app_data(home: &std::path::Path) -> PathBuf {
    env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| default_app_data_in(home))
}

#[cfg(not(windows))]
fn default_app_data(home: &std::path::Path) -> PathBuf {
    default_app_data_in(home)
}

fn default_app_data_in(home: &std::path::Path) -> PathBuf {
    if cfg!(windows) {
        home.join("AppData").join("Roaming")
    } else if cfg!(target_os = "macos") {
        home.join("Library").join("Application Support")
    } else {
        home.join(".config")
    }
}

fn default_data_dir(home: &std::path::Path) -> PathBuf {
    #[cfg(windows)]
    if let Some(p) = env::var_os("LOCALAPPDATA") {
        return PathBuf::from(p).join("Burn");
    }
    // Development on a Mac: keep clear of the Mac app's own store.
    home.join(".burn-dev")
}
