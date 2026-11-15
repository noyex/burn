//! App state and its refresh schedule, a port of `AppModel.swift`. The panel gets the whole state
//! as one `Snapshot` on every change; the taskbar widget gets its entries.

use burn_core::database::UsageDatabase;
use burn_core::settings::{Settings, pick_windows};
use burn_core::shelf::{Shelf, ShelfItem};
use burn_core::{LimitsError, Paths, Period, ProviderId, ProviderLimits, UsageSummary, importer, limits};
use serde::Serialize;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const LIMITS_EVERY: Duration = Duration::from_secs(120);
const SYNC_EVERY: Duration = Duration::from_secs(300);
/// Opening the panel refreshes what's older than this.
const LIMITS_STALE_ON_OPEN: Duration = Duration::from_secs(30);
const SYNC_STALE_ON_OPEN: Duration = Duration::from_secs(60);
/// Screenshots past their retention go within the hour.
const PRUNE_EVERY: Duration = Duration::from_secs(3600);

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum LimitState {
    Loading,
    Loaded {
        limits: ProviderLimits,
    },
    /// Credentials are missing or expired; the user has to sign in with the provider's CLI.
    SignedOut,
    /// Keeps the last good value so a transient failure doesn't blank the UI.
    Failed {
        message: String,
        last: Option<ProviderLimits>,
    },
}

impl LimitState {
    pub fn limits(&self) -> Option<&ProviderLimits> {
        match self {
            LimitState::Loaded { limits } => Some(limits),
            LimitState::Failed { last, .. } => last.as_ref(),
            _ => None,
        }
    }
}

/// Everything the panel shows.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub connected: Vec<ProviderId>,
    pub limits: BTreeMap<ProviderId, LimitState>,
    pub usage: Option<UsageSummary>,
    pub usage_error: Option<String>,
    pub period: Period,
    /// Epoch ms of the last finished import.
    pub last_sync: Option<i64>,
    pub syncing: bool,
    /// Percent of the running import, only while one runs.
    pub import_percent: Option<u32>,
    /// False until at least one usage record exists.
    pub has_usage: bool,
    pub settings: Settings,
    /// Whether Windows starts Burn at login (the Run key, not a setting of our own).
    pub launch_at_login: bool,
    pub version: &'static str,
    /// Saved screenshots, newest first.
    pub shelf: Vec<ShelfItem>,
    /// Version of a newer release, when there is one.
    pub update: Option<String>,
    /// The update is downloading and installing.
    pub updating: bool,
}

/// One provider in the taskbar widget.
#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Clone, Debug, PartialEq)]
pub struct WidgetEntry {
    pub provider: ProviderId,
    pub used: f64,
    pub resets_at: Option<i64>,
    /// False for a provider's second and later windows, drawn after the first without a logo.
    pub logo: bool,
}

struct State {
    snap: Snapshot,
    limits_fetched_at: Option<Instant>,
    synced_at: Option<Instant>,
    refreshing_limits: bool,
}

/// Called after every change, from whichever thread made it.
pub type Listener = Box<dyn Fn(&Snapshot) + Send + Sync>;

pub struct Model {
    paths: Paths,
    state: Mutex<State>,
    /// Captures run one after another so file names and the repeat check never race.
    shelf: Mutex<Shelf>,
    shelf_dir: std::path::PathBuf,
    listener: Mutex<Option<Listener>>,
}

impl Model {
    pub fn new(paths: Paths) -> Arc<Model> {
        let settings = Settings::load(&settings_path(&paths));
        Arc::new(Model {
            state: Mutex::new(State {
                snap: Snapshot {
                    connected: Vec::new(),
                    limits: BTreeMap::new(),
                    usage: None,
                    usage_error: None,
                    period: Period::All,
                    last_sync: None,
                    syncing: false,
                    import_percent: None,
                    has_usage: true,
                    settings,
                    launch_at_login: false,
                    version: env!("CARGO_PKG_VERSION"),
                    shelf: Vec::new(),
                    update: None,
                    updating: false,
                },
                limits_fetched_at: None,
                synced_at: None,
                refreshing_limits: false,
            }),
            shelf_dir: Shelf::new(&paths.data_dir).dir().to_path_buf(),
            shelf: Mutex::new(Shelf::new(&paths.data_dir)),
            paths,
            listener: Mutex::new(None),
        })
    }

    pub fn set_listener(&self, l: Listener) {
        *lock(&self.listener) = Some(l);
    }

    pub fn snapshot(&self) -> Snapshot {
        lock(&self.state).snap.clone()
    }

    fn changed(&self) {
        let snap = self.snapshot();
        if let Some(l) = lock(&self.listener).as_ref() {
            l(&snap);
        }
    }

    /// Loads what's on disk, then keeps limits and usage fresh in the background.
    pub fn start(self: &Arc<Self>) {
        let m = self.clone();
        std::thread::Builder::new()
            .name("burn-scheduler".into())
            .spawn(move || {
                m.load_shelf();
                m.load_usage();
                m.spawn_refresh_limits();
                m.sync();
                let mut next_limits = Instant::now() + LIMITS_EVERY;
                let mut next_sync = Instant::now() + SYNC_EVERY;
                let mut next_prune = Instant::now() + PRUNE_EVERY;
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    let now = Instant::now();
                    if now >= next_limits {
                        next_limits = now + LIMITS_EVERY;
                        m.spawn_refresh_limits();
                    }
                    if now >= next_sync {
                        next_sync = now + SYNC_EVERY;
                        m.sync();
                    }
                    if now >= next_prune {
                        next_prune = now + PRUNE_EVERY;
                        m.load_shelf();
                    }
                }
            })
            .expect("scheduler thread");
    }

    /// The panel opened: refresh whatever is getting old.
    pub fn panel_opened(self: &Arc<Self>) {
        let (limits_stale, sync_stale) = {
            let s = lock(&self.state);
            (
                s.limits_fetched_at.is_none_or(|t| t.elapsed() > LIMITS_STALE_ON_OPEN),
                s.synced_at.is_none_or(|t| t.elapsed() > SYNC_STALE_ON_OPEN),
            )
        };
        if limits_stale {
            self.spawn_refresh_limits();
        }
        if sync_stale {
            let m = self.clone();
            std::thread::spawn(move || m.sync());
        }
    }

    pub fn set_period(self: &Arc<Self>, period: Period) {
        {
            let mut s = lock(&self.state);
            if s.snap.period == period {
                return;
            }
            s.snap.period = period;
        }
        let m = self.clone();
        std::thread::spawn(move || m.load_usage());
    }

    /// Replaces the settings, saves them and tells everyone.
    pub fn set_settings(self: &Arc<Self>, settings: Settings) {
        let retention_changed = {
            let mut s = lock(&self.state);
            if s.snap.settings == settings {
                return;
            }
            let changed = s.snap.settings.shelf_retention_days != settings.shelf_retention_days;
            s.snap.settings = settings.clone();
            changed
        };
        if retention_changed {
            let m = self.clone();
            std::thread::spawn(move || m.load_shelf());
        }
        if let Err(e) = settings.save(&settings_path(&self.paths)) {
            crate::log!("saving settings failed: {e}");
        }
        self.changed();
    }

    // ---- Shelf -----------------------------------------------------------------------------

    pub fn shelf_dir(&self) -> &std::path::Path {
        &self.shelf_dir
    }

    /// Publishes the shelf's list while still holding the shelf lock, so a slower writer can't
    /// replace a newer list with an older one.
    fn publish_shelf(&self, items: Vec<ShelfItem>) {
        lock(&self.state).snap.shelf = items;
    }

    /// Loads the shelf, drops what's past retention and makes missing previews. Blocking.
    pub fn load_shelf(&self) {
        let days = lock(&self.state).snap.settings.shelf_retention_days;
        {
            let mut shelf = lock(&self.shelf);
            let items = shelf.prune(days, std::time::SystemTime::now());
            shelf.ensure_thumbs();
            self.publish_shelf(items);
        }
        self.changed();
    }

    #[cfg_attr(not(windows), allow(dead_code))]
    /// Keeps a copied image (PNG bytes). Blocking: hashes, writes the file and its preview.
    pub fn capture(&self, png: &[u8]) {
        let days = lock(&self.state).snap.settings.shelf_retention_days;
        {
            let mut shelf = lock(&self.shelf);
            match shelf.save(png, std::time::SystemTime::now()) {
                Ok(Some(_)) => {}
                Ok(None) => return,
                Err(e) => {
                    crate::log!("saving a copied image failed: {e}");
                    return;
                }
            }
            self.publish_shelf(shelf.prune(days, std::time::SystemTime::now()));
        }
        self.changed();
    }

    pub fn delete_shelf(&self, paths: Option<&[std::path::PathBuf]>) {
        {
            let mut shelf = lock(&self.shelf);
            match paths {
                Some(p) => shelf.delete(p),
                None => shelf.clear(),
            }
            self.publish_shelf(shelf.items());
        }
        self.changed();
    }

    pub fn set_update(&self, version: Option<String>) {
        lock(&self.state).snap.update = version;
        self.changed();
    }

    pub fn set_updating(&self, on: bool) {
        lock(&self.state).snap.updating = on;
        self.changed();
    }

    /// A summary of `period` straight from the store (the snapshot may still hold the previous one).
    pub fn usage_for(&self, period: Period) -> Option<UsageSummary> {
        UsageDatabase::new(self.paths.db_path()).summary(period).ok()
    }

    pub fn set_launch_at_login(&self, on: bool) {
        lock(&self.state).snap.launch_at_login = on;
        self.changed();
    }

    /// What the taskbar widget shows: each connected provider's chosen window.
    #[cfg_attr(not(windows), allow(dead_code))]
    pub fn widget_entries(&self) -> Vec<WidgetEntry> {
        let s = lock(&self.state);
        let snap = &s.snap;
        snap.connected
            .iter()
            .filter(|p| snap.settings.shows_in_widget(**p))
            .flat_map(|p| {
                let Some(limits) = snap.limits.get(p).and_then(|l| l.limits()) else {
                    return Vec::new();
                };
                let choices = snap.settings.widget_window_list(*p);
                let shown = pick_windows(&choices, limits);
                shown
                    .iter()
                    .enumerate()
                    .map(|(i, w)| WidgetEntry { provider: *p, used: w.percent, resets_at: w.resets_at, logo: i == 0 })
                    .collect()
            })
            .collect()
    }

    // ---- Limits ----------------------------------------------------------------------------

    fn spawn_refresh_limits(self: &Arc<Self>) {
        let m = self.clone();
        std::thread::spawn(move || m.refresh_limits());
    }

    fn refresh_limits(self: &Arc<Self>) {
        {
            let mut s = lock(&self.state);
            if s.refreshing_limits {
                return;
            }
            s.refreshing_limits = true;
            s.limits_fetched_at = Some(Instant::now());
        }
        // Re-detect on every refresh so signing in or out shows up without a restart.
        let now: Vec<ProviderId> =
            ProviderId::ALL.into_iter().filter(|p| limits::is_connected(*p, &self.paths)).collect();
        let changed = {
            let mut s = lock(&self.state);
            let changed = s.snap.connected != now;
            if changed {
                s.snap.limits.retain(|p, _| now.contains(p));
                for p in &now {
                    s.snap.limits.entry(*p).or_insert(LimitState::Loading);
                }
                s.snap.connected = now.clone();
            }
            changed
        };
        if changed {
            self.changed();
        }

        let handles: Vec<_> = now
            .into_iter()
            .map(|p| {
                let paths = self.paths.clone();
                (p, std::thread::spawn(move || limits::fetch(p, &paths)))
            })
            .collect();
        for (p, h) in handles {
            let result = h.join().unwrap_or(Err(LimitsError::BadResponse));
            {
                let mut s = lock(&self.state);
                let last = s.snap.limits.get(&p).and_then(|l| l.limits().cloned());
                let next = match result {
                    Ok(l) => LimitState::Loaded { limits: l },
                    Err(LimitsError::TokenExpired | LimitsError::NotConnected) => LimitState::SignedOut,
                    Err(e) => {
                        crate::log!("{} limits failed: {e:?}", p.name());
                        LimitState::Failed { message: e.to_string(), last }
                    }
                };
                s.snap.limits.insert(p, next);
            }
            self.changed();
        }
        lock(&self.state).refreshing_limits = false;
    }

    // ---- Usage -----------------------------------------------------------------------------

    fn sync(self: &Arc<Self>) {
        {
            let mut s = lock(&self.state);
            if s.snap.syncing {
                return;
            }
            s.snap.syncing = true;
        }
        self.changed();
        let progress = |p: importer::ImportProgress| {
            if p.total == 0 {
                return;
            }
            let pct = (p.done * 100 / p.total) as u32;
            let changed = {
                let mut s = lock(&self.state);
                let changed = s.snap.import_percent != Some(pct);
                s.snap.import_percent = Some(pct);
                changed
            };
            if changed {
                self.changed();
            }
        };
        let started = Instant::now();
        match importer::run(&self.paths, &progress) {
            Ok(r) => {
                if r.parsed_files > 0 {
                    crate::log!(
                        "import: {} files, {} new rows, {} total in {:.2} s",
                        r.parsed_files,
                        r.new_rows,
                        r.total_rows,
                        started.elapsed().as_secs_f64()
                    );
                }
                let mut s = lock(&self.state);
                s.snap.last_sync = Some(chrono::Utc::now().timestamp_millis());
                s.synced_at = Some(Instant::now());
            }
            Err(e) => crate::log!("import failed: {e:#}"),
        }
        {
            let mut s = lock(&self.state);
            s.snap.syncing = false;
            s.snap.import_percent = None;
        }
        self.load_usage();
    }

    fn load_usage(&self) {
        let period = lock(&self.state).snap.period;
        let db = UsageDatabase::new(self.paths.db_path());
        let result = db.summary(period);
        let any = db.has_any_usage().unwrap_or(false);
        {
            let mut s = lock(&self.state);
            s.snap.has_usage = any;
            // The user picked another period meanwhile; its own load will land.
            if s.snap.period != period {
                return;
            }
            match result {
                Ok(u) => {
                    s.snap.usage = Some(u);
                    s.snap.usage_error = None;
                }
                Err(e) => s.snap.usage_error = Some(format!("{e:#}")),
            }
        }
        self.changed();
    }
}

fn settings_path(paths: &Paths) -> std::path::PathBuf {
    paths.data_dir.join("settings.json")
}

/// A poisoned lock only means another thread panicked mid-update; the data is still usable.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
