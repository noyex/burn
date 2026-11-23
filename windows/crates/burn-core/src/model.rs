//! Shared data types. Mirrors `Models.swift`. Times are epoch milliseconds (UTC) so the
//! web UI can use them directly.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderId {
    Claude,
    Codex,
    Cursor,
    Antigravity,
}

impl ProviderId {
    pub const ALL: [ProviderId; 4] =
        [ProviderId::Claude, ProviderId::Codex, ProviderId::Cursor, ProviderId::Antigravity];

    pub fn as_str(self) -> &'static str {
        match self {
            ProviderId::Claude => "claude",
            ProviderId::Codex => "codex",
            ProviderId::Cursor => "cursor",
            ProviderId::Antigravity => "antigravity",
        }
    }

    pub fn parse(s: &str) -> Option<ProviderId> {
        Self::ALL.into_iter().find(|p| p.as_str() == s)
    }

    pub fn name(self) -> &'static str {
        match self {
            ProviderId::Claude => "Claude",
            ProviderId::Codex => "Codex",
            ProviderId::Cursor => "Cursor",
            ProviderId::Antigravity => "Antigravity",
        }
    }

    /// Official CLI command that signs in; Burn reads the credentials it stores.
    pub fn login_command(self) -> &'static str {
        match self {
            ProviderId::Claude => "claude auth login",
            ProviderId::Codex => "codex login",
            ProviderId::Cursor => "cursor-agent login",
            ProviderId::Antigravity => "agy",
        }
    }
}

/// One rate-limit window of a provider, e.g. Claude's 5-hour or weekly limit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitWindow {
    /// Stable key used to remember the user's choice, e.g. "5h", "week", "month", "total", "api".
    pub id: String,
    /// Short label shown in the UI, e.g. "5h", "Week", "Month", "API".
    pub label: String,
    /// 0...100 (may exceed 100 if the provider reports overage).
    pub percent: f64,
    pub resets_at: Option<i64>,
    /// A narrower cap (e.g. one model's weekly limit) shown as a small line, not a big number.
    #[serde(default)]
    pub minor: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderLimits {
    pub provider: ProviderId,
    /// Human-readable plan, e.g. "Max 5x", "Pro", "Free".
    pub plan: Option<String>,
    /// Ordered from shortest to longest window.
    pub windows: Vec<LimitWindow>,
    pub fetched_at: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LimitsError {
    NotConnected,
    TokenExpired,
    Http(u16),
    BadResponse,
    /// Transport failure (DNS, TLS, timeout). Codex falls back to its session snapshot on these.
    Network(String),
}

impl fmt::Display for LimitsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LimitsError::NotConnected => write!(f, "Not signed in"),
            LimitsError::TokenExpired => write!(f, "Session expired, open the app to sign in again"),
            LimitsError::Http(code) => write!(f, "Request failed ({code})"),
            LimitsError::BadResponse => write!(f, "Unexpected response"),
            LimitsError::Network(_) => write!(f, "No connection"),
        }
    }
}

impl std::error::Error for LimitsError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Period {
    Today,
    Week,
    Month,
    All,
}

impl Period {
    pub const ALL: [Period; 4] = [Period::Today, Period::Week, Period::Month, Period::All];

    pub fn title(self) -> &'static str {
        match self {
            Period::Today => "Today",
            Period::Week => "7D",
            Period::Month => "30D",
            Period::All => "All",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BucketUnit {
    Hour,
    Day,
    Week,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageBucket {
    /// Local start of the bucket, epoch ms.
    pub start: i64,
    pub cost: BTreeMap<ProviderId, f64>,
}

impl UsageBucket {
    pub fn total(&self) -> f64 {
        // `sum()` of nothing is -0.0, which prints as "-0.00".
        self.cost.values().fold(0.0, |a, b| a + b)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    pub period: Period,
    pub cost: f64,
    pub tokens: i64,
    pub by_provider: BTreeMap<ProviderId, f64>,
    /// Contiguous buckets (zero-filled) covering the period, oldest first.
    pub buckets: Vec<UsageBucket>,
    pub unit: BucketUnit,
}
