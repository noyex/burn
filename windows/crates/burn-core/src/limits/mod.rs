//! Live rate limits of each provider. Blocking; call from a worker thread.

mod antigravity;
mod claude;
mod codex;
mod cursor;
pub(crate) mod http;

use crate::model::{LimitsError, ProviderId, ProviderLimits};
use crate::paths::Paths;

/// Cheap local check (credentials present). Never hits the network.
pub fn is_connected(provider: ProviderId, paths: &Paths) -> bool {
    match provider {
        ProviderId::Claude => claude::is_connected(paths),
        ProviderId::Codex => codex::is_connected(paths),
        ProviderId::Cursor => cursor::is_connected(paths),
        ProviderId::Antigravity => antigravity::is_connected(paths),
    }
}

pub fn fetch(provider: ProviderId, paths: &Paths) -> Result<ProviderLimits, LimitsError> {
    match provider {
        ProviderId::Claude => claude::fetch(paths),
        ProviderId::Codex => codex::fetch(paths),
        ProviderId::Cursor => cursor::fetch(paths),
        ProviderId::Antigravity => antigravity::fetch(paths),
    }
}
