//! User preferences, a port of `Settings.swift`. Persisted as `settings.json` in Burn's data dir.
//! Launch at login is not stored here: the HKCU Run key is the source of truth.

use crate::model::{LimitWindow, ProviderId, ProviderLimits};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// Window choice meaning "whichever is most used".
pub const HIGHEST: &str = "highest";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum PanelLayout {
    Auto,
    Grid,
    List,
    #[default]
    Custom,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum PanelOrder {
    #[default]
    Manual,
    ClosestToLimit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CardSize {
    S,
    M,
    L,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CardColor {
    Coral,
    Mono,
    Lavender,
    Sky,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Tab {
    #[default]
    Usage,
    Shelf,
}

/// Everything the user can change. Unknown or missing fields fall back to the defaults, so an
/// older or newer file never fails to load.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Providers left out of the taskbar widget.
    pub widget_hidden: Vec<ProviderId>,
    /// Window id shown in the widget per provider, or `highest`.
    pub widget_windows: BTreeMap<ProviderId, String>,
    /// Providers hidden from the panel.
    pub panel_hidden: Vec<ProviderId>,
    pub card_sizes: BTreeMap<ProviderId, CardSize>,
    pub card_colors: BTreeMap<ProviderId, CardColor>,
    /// Window shown big on each card, or `highest`. Separate from the widget choice.
    pub card_windows: BTreeMap<ProviderId, String>,
    /// Every provider, in the manual order of the panel.
    pub provider_order: Vec<ProviderId>,
    pub panel_layout: PanelLayout,
    pub panel_order: PanelOrder,
    pub shows_spending: bool,
    pub tab: Tab,
    pub shelf_expanded: bool,
    /// Screenshots older than this are deleted; 0 keeps them until cleared.
    pub shelf_retention_days: u32,
    /// Show a notification-area icon instead of the taskbar widget.
    pub tray_only: bool,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            widget_hidden: Vec::new(),
            widget_windows: BTreeMap::new(),
            panel_hidden: Vec::new(),
            card_sizes: BTreeMap::new(),
            card_colors: BTreeMap::new(),
            card_windows: BTreeMap::new(),
            provider_order: ProviderId::ALL.to_vec(),
            panel_layout: PanelLayout::Custom,
            panel_order: PanelOrder::Manual,
            shows_spending: true,
            tab: Tab::Usage,
            shelf_expanded: false,
            shelf_retention_days: 7,
            tray_only: false,
        }
    }
}

impl Settings {
    /// Reads `path`; a missing or unreadable file gives the defaults.
    pub fn load(path: &Path) -> Settings {
        let mut s: Settings =
            std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        s.normalize();
        s
    }

    /// Writes atomically, so a crash mid-write never leaves a broken file.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)?;
        std::fs::rename(&tmp, path)
    }

    /// Saved order, without duplicates, plus providers it doesn't know yet.
    fn normalize(&mut self) {
        let mut order = Vec::new();
        for p in self.provider_order.iter().chain(ProviderId::ALL.iter()) {
            if !order.contains(p) {
                order.push(*p);
            }
        }
        self.provider_order = order;
    }

    pub fn shows_in_widget(&self, p: ProviderId) -> bool {
        !self.widget_hidden.contains(&p)
    }

    pub fn widget_window(&self, p: ProviderId) -> &str {
        self.widget_windows.get(&p).map_or_else(|| default_window(p), String::as_str)
    }

    /// Every window the widget shows for `p`: the setting may list several, comma-separated.
    pub fn widget_window_list(&self, p: ProviderId) -> Vec<&str> {
        self.widget_window(p).split(',').map(str::trim).filter(|s| !s.is_empty()).collect()
    }

    pub fn card_window(&self, p: ProviderId) -> &str {
        self.card_windows.get(&p).map_or_else(|| default_window(p), String::as_str)
    }
}

fn default_window(p: ProviderId) -> &'static str {
    match p {
        // The 5-hour window is the one that actually blocks work during the day.
        ProviderId::Claude => "5h",
        // Cursor's API bucket often sits at 100% while the plan as a whole is fine.
        ProviderId::Cursor => "total",
        ProviderId::Codex => HIGHEST,
    }
}

/// The chosen window, or the most used one when the choice is `highest` or not reported.
pub fn pick_window<'a>(choice: &str, limits: &'a ProviderLimits) -> Option<&'a LimitWindow> {
    if choice != HIGHEST
        && let Some(w) = limits.windows.iter().find(|w| w.id == choice)
    {
        return Some(w);
    }
    limits.windows.iter().max_by(|a, b| a.percent.total_cmp(&b.percent))
}

/// Every window the widget shows for a setting like `5h`, `5h,week` or `all`. `all` leaves out minor caps,
/// and an id inside a list that the provider no longer reports is skipped instead of replaced. Falls back
/// to the most used window, so a provider with any window never drops out of the widget.
pub fn pick_windows<'a>(choices: &[&str], limits: &'a ProviderLimits) -> Vec<&'a LimitWindow> {
    let mut shown: Vec<&LimitWindow> = Vec::new();
    for &choice in choices {
        let picked: Vec<&LimitWindow> = match choice {
            "all" => limits.windows.iter().filter(|w| !w.minor).collect(),
            _ if choices.len() > 1 && choice != HIGHEST => limits.windows.iter().filter(|w| w.id == choice).collect(),
            _ => pick_window(choice, limits).into_iter().collect(),
        };
        for w in picked {
            if !shown.iter().any(|s| s.id == w.id) {
                shown.push(w);
            }
        }
    }
    if shown.is_empty() {
        shown.extend(pick_window(HIGHEST, limits));
    }
    shown
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(id: &str, percent: f64) -> LimitWindow {
        LimitWindow { id: id.into(), label: id.into(), percent, resets_at: None, minor: false }
    }

    #[test]
    fn defaults_and_partial_files() {
        let s: Settings =
            serde_json::from_str(r#"{"showsSpending": false, "providerOrder": ["cursor", "cursor"]}"#).unwrap();
        let mut s = s;
        s.normalize();
        assert!(!s.shows_spending);
        assert_eq!(s.shelf_retention_days, 7);
        assert_eq!(s.provider_order, vec![ProviderId::Cursor, ProviderId::Claude, ProviderId::Codex]);
        assert_eq!(s.widget_window(ProviderId::Claude), "5h");
        let mut both = s.clone();
        both.widget_windows.insert(ProviderId::Claude, "5h, week".into());
        assert_eq!(both.widget_window_list(ProviderId::Claude), ["5h", "week"]);
        assert_eq!(s.card_window(ProviderId::Codex), HIGHEST);
    }

    #[test]
    fn picks_the_chosen_or_highest_window() {
        let l = ProviderLimits {
            provider: ProviderId::Claude,
            plan: None,
            windows: vec![window("5h", 10.0), window("week", 60.0)],
            fetched_at: 0,
        };
        assert_eq!(pick_window("5h", &l).unwrap().id, "5h");
        assert_eq!(pick_window(HIGHEST, &l).unwrap().id, "week");
        assert_eq!(pick_window("gone", &l).unwrap().id, "week");
    }

    #[test]
    fn picks_several_windows() {
        let mut fable = window("week_fable", 90.0);
        fable.minor = true;
        let l = ProviderLimits {
            provider: ProviderId::Claude,
            plan: None,
            windows: vec![window("5h", 10.0), window("week", 60.0), fable],
            fetched_at: 0,
        };
        let ids = |choices: &[&str]| pick_windows(choices, &l).iter().map(|w| w.id.as_str()).collect::<Vec<_>>();
        assert_eq!(ids(&["5h", "week"]), ["5h", "week"]);
        assert_eq!(ids(&["all"]), ["5h", "week"]);
        assert_eq!(ids(&["5h", "gone"]), ["5h"]);
        assert_eq!(ids(&["gone"]), ["week_fable"]);
        assert_eq!(ids(&[]), ["week_fable"]);
        assert_eq!(ids(&["gone", "lost"]), ["week_fable"]);
    }

    #[test]
    fn round_trips_through_a_file() {
        let path = std::env::temp_dir().join(format!("burn-settings-{}.json", std::process::id()));
        let mut s = Settings::default();
        s.card_sizes.insert(ProviderId::Codex, CardSize::L);
        s.save(&path).unwrap();
        assert_eq!(Settings::load(&path), s);
        let _ = std::fs::remove_file(&path);
    }
}
