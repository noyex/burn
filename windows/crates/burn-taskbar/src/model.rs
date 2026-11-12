//! What the widget shows, independent of how it is drawn. Mirrors the Mac menu bar
//! (`MenuBarImage` in StatusItemController.swift).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Claude,
    Codex,
    Cursor,
}

impl Provider {
    pub fn name(self) -> &'static str {
        match self {
            Provider::Claude => "Claude",
            Provider::Codex => "Codex",
            Provider::Cursor => "Cursor",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub provider: Provider,
    /// Percent of the limit used, 0–100.
    pub used: f64,
    /// Seconds until the limit resets.
    pub resets_in: Option<u64>,
}

/// Same thresholds as the Mac app: orange at 20% left, red at 0%.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Normal,
    Warn,
    Full,
}

pub const WARN_PERCENT: f64 = 80.0;

impl Level {
    pub fn from_used(used: f64) -> Level {
        // From the rounded share left, so an entry reading "0%" is always Full.
        let left = (100.0 - used).clamp(0.0, 100.0).round();
        if left <= 0.0 {
            Level::Full
        } else if left <= 100.0 - WARN_PERCENT {
            Level::Warn
        } else {
            Level::Normal
        }
    }
}

pub fn remaining(used: f64) -> String {
    format!("{}%", (100.0 - used).clamp(0.0, 100.0).round() as i64)
}

/// Compact reset time for the taskbar: "now", "45m", "3h", "2d".
pub fn short_reset(secs: u64) -> String {
    match secs {
        0 => "now".into(),
        s if s < 3600 => format!("{}m", (s / 60).max(1)),
        s if s < 86_400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86_400),
    }
}

/// "2h 10m" style, for the panel.
pub fn reset(secs: u64) -> String {
    match secs {
        0 => "now".into(),
        s if s < 3600 => format!("{}m", (s / 60).max(1)),
        s if s < 86_400 => {
            let (h, m) = (s / 3600, (s % 3600) / 60);
            if m == 0 { format!("{h}h") } else { format!("{h}h {m}m") }
        }
        s => format!("{}d", s / 86_400),
    }
}

/// The taskbar label of one entry: "58%", or "0% · 2h" once the limit is used up.
pub fn label(entry: &Entry) -> String {
    let mut text = remaining(entry.used);
    if Level::from_used(entry.used) == Level::Full
        && let Some(secs) = entry.resets_in
    {
        text.push_str(" · ");
        text.push_str(&short_reset(secs));
    }
    text
}

/// Fixed sets the spike cycles through, so width changes and every colour can be checked.
pub fn demo_sets() -> Vec<Vec<Entry>> {
    use Provider::*;
    let e = |provider, used, resets_in| Entry { provider, used, resets_in: Some(resets_in) };
    vec![
        vec![e(Claude, 42.0, 7_800), e(Codex, 88.0, 2_400), e(Cursor, 30.0, 950_000)],
        vec![e(Claude, 100.0, 7_800), e(Codex, 50.0, 14_000), e(Cursor, 96.0, 950_000)],
        vec![e(Claude, 7.0, 16_000)],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_match_the_mac_thresholds() {
        assert_eq!(Level::from_used(42.0), Level::Normal);
        assert_eq!(Level::from_used(80.0), Level::Warn);
        assert_eq!(Level::from_used(79.4), Level::Normal);
        assert_eq!(Level::from_used(99.6), Level::Full);
        assert_eq!(Level::from_used(120.0), Level::Full);
    }

    #[test]
    fn labels() {
        let full = Entry { provider: Provider::Claude, used: 100.0, resets_in: Some(7_800) };
        assert_eq!(label(&full), "0% · 2h");
        let normal = Entry { provider: Provider::Codex, used: 42.4, resets_in: Some(60) };
        assert_eq!(label(&normal), "58%");
        assert_eq!(short_reset(59), "1m");
        assert_eq!(reset(7_800), "2h 10m");
        assert_eq!(reset(7_200), "2h");
    }
}
