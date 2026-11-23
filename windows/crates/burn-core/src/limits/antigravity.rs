//! Google Antigravity usage limits (`v1internal:retrieveUserQuotaSummary` / `fetchAvailableModels`).
//! Mirrors `AntigravityLimits.swift` and T3 Code's `antigravityUsageLimits.ts`.

use super::http::{self, json_f64, now_ms, parse_iso_ms};
use crate::model::{LimitWindow, LimitsError, ProviderId, ProviderLimits};
use crate::paths::Paths;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::UNIX_EPOCH;

const DAILY_ENDPOINT: &str = "https://daily-cloudcode-pa.googleapis.com";
const PROD_ENDPOINT: &str = "https://cloudcode-pa.googleapis.com";

fn user_agent() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)"
    }
    #[cfg(all(target_os = "macos", not(target_arch = "aarch64")))]
    {
        "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=x64; cl=963137146)"
    }
    #[cfg(all(target_os = "windows", target_arch = "aarch64"))]
    {
        "antigravity/hub/2.24.0 (aidev_client; os_type=win32; arch=arm64; cl=963137146)"
    }
    #[cfg(all(target_os = "windows", not(target_arch = "aarch64")))]
    {
        "antigravity/hub/2.24.0 (aidev_client; os_type=win32; arch=x64; cl=963137146)"
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        "antigravity/hub/2.24.0 (aidev_client; os_type=linux; arch=x64; cl=963137146)"
    }
}

#[derive(Clone)]
struct RefreshedToken {
    fingerprint: String,
    access_token: String,
    expires_at_ms: i64,
}

static TOKEN_CACHE: LazyLock<Mutex<Option<RefreshedToken>>> = LazyLock::new(|| Mutex::new(None));

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AuthMethod {
    Personal,
    Business,
}

impl AuthMethod {
    fn endpoints(self) -> [&'static str; 2] {
        match self {
            AuthMethod::Personal => [DAILY_ENDPOINT, PROD_ENDPOINT],
            AuthMethod::Business => [PROD_ENDPOINT, DAILY_ENDPOINT],
        }
    }
}

struct TokenSource {
    acp_token: Option<PathBuf>,
    cli_token: Option<PathBuf>,
    auth_method: AuthMethod,
    mtime: f64,
}

fn candidate_dirs(paths: &Paths) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    let t3_root = paths.t3_userdata().join("providers").join("antigravity");
    if let Ok(entries) = std::fs::read_dir(&t3_root) {
        let mut names: Vec<PathBuf> = entries.flatten().map(|e| e.path().join("antigravity-acp")).collect();
        names.sort();
        dirs.extend(names);
    }
    for name in ["antigravity-cli", "antigravity", "antigravity-ide"] {
        dirs.push(paths.home.join(".gemini").join(name));
    }
    dirs.push(paths.home.join(".config").join("antigravity"));
    dirs
}

fn file_mtime(path: &Path) -> Option<f64> {
    let m = std::fs::metadata(path).ok()?;
    if !m.is_file() {
        return None;
    }
    let t = m.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some(t.as_secs_f64())
}

fn read_auth_method(dir: &Path) -> AuthMethod {
    let path = dir.join("cache").join("acp-auth-state.json");
    if let Ok(raw) = std::fs::read_to_string(path)
        && let Ok(v) = serde_json::from_str::<Value>(&raw)
        && v.get("methodId").and_then(Value::as_str) == Some("oauth-business")
    {
        return AuthMethod::Business;
    }
    AuthMethod::Personal
}

fn token_sources(paths: &Paths) -> Vec<TokenSource> {
    let mut out = Vec::new();
    for dir in candidate_dirs(paths) {
        let acp = dir.join("acp_token.json");
        let cli = dir.join("antigravity-oauth-token");
        let acp_m = file_mtime(&acp);
        let cli_m = file_mtime(&cli);
        if acp_m.is_some() || cli_m.is_some() {
            out.push(TokenSource {
                acp_token: acp_m.map(|_| acp),
                cli_token: cli_m.map(|_| cli),
                auth_method: read_auth_method(&dir),
                mtime: acp_m.unwrap_or(0.0).max(cli_m.unwrap_or(0.0)),
            });
        }
    }
    out.sort_by(|a, b| b.mtime.total_cmp(&a.mtime));
    out
}

pub fn is_connected(paths: &Paths) -> bool {
    if !token_sources(paths).is_empty() {
        return true;
    }
    #[cfg(target_os = "macos")]
    {
        http::keychain_item_exists("gemini", Some("antigravity"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

pub(crate) fn decode_go_keyring_secret(raw: &str) -> String {
    if let Some(b64) = raw.strip_prefix("go-keyring-base64:")
        && let Some(bytes) = decode_base64(b64)
        && let Ok(s) = String::from_utf8(bytes)
    {
        return s;
    }
    if let Some(hex) = raw.strip_prefix("go-keyring-encoded:")
        && let Some(bytes) = decode_hex(hex)
        && let Ok(s) = String::from_utf8(bytes)
    {
        return s;
    }
    raw.to_string()
}

fn decode_hex(s: &str) -> Option<Vec<u8>> {
    let b = s.as_bytes();
    if !b.len().is_multiple_of(2) {
        return None;
    }
    let val = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'A'..=b'F' => Some(c - b'A' + 10),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    let mut out = Vec::with_capacity(b.len() / 2);
    for pair in b.chunks_exact(2) {
        out.push((val(pair[0])? << 4) | val(pair[1])?);
    }
    Some(out)
}

fn decode_base64(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for b in s.bytes() {
        if b.is_ascii_whitespace() || b == b'=' {
            continue;
        }
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        buf = (buf << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xff) as u8);
        }
    }
    Some(out)
}

/// The OAuth client the `agy` CLI signs in with. Its token file and keychain item carry a
/// refresh token but no client, and the access token lasts an hour, so Burn refreshes it
/// itself (in memory, never writing the CLI's files). This is an installed-app client, whose
/// secret Google documents as not confidential; it ships inside the `agy` binary.
const CLI_CLIENT_ID: &str = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";
const CLI_CLIENT_SECRET_PARTS: [&str; 2] = ["GOCSPX-", "K58FWR486LdLJ1mLB8sXC4z6qDAf"];

#[derive(Debug, PartialEq)]
enum ParsedCliToken {
    Valid(String, Option<AuthMethod>),
    /// Carries the refresh token, if any, and the auth method.
    Expired(Option<String>, Option<AuthMethod>),
    Invalid,
}

/// Trades the CLI's refresh token for a fresh access token. `None` when there is no refresh
/// token or Google rejects it (the user really is signed out).
fn refresh_cli_token(refresh_token: Option<&str>) -> Option<String> {
    let secret = CLI_CLIENT_SECRET_PARTS.concat();
    refresh_oauth_token(CLI_CLIENT_ID, &secret, refresh_token?, None).ok()
}

fn parse_cli_token(raw: &str, now: i64) -> ParsedCliToken {
    let Ok(v) = serde_json::from_str::<Value>(raw) else { return ParsedCliToken::Invalid };
    let Some(tok) = v.get("token").filter(|t| t.is_object()) else { return ParsedCliToken::Invalid };
    let Some(access) = tok.get("access_token").and_then(Value::as_str).filter(|s| !s.is_empty()) else {
        return ParsedCliToken::Invalid;
    };
    let method = match v.get("auth_method").and_then(Value::as_str) {
        Some("oauth-business" | "business" | "enterprise") => Some(AuthMethod::Business),
        Some("oauth-personal" | "consumer" | "personal") => Some(AuthMethod::Personal),
        _ => None,
    };
    match tok.get("expiry").and_then(Value::as_str).and_then(parse_iso_ms) {
        Some(exp) if exp > now + 60_000 => ParsedCliToken::Valid(access.to_string(), method),
        _ => {
            let refresh = tok.get("refresh_token").and_then(Value::as_str).filter(|s| !s.is_empty());
            ParsedCliToken::Expired(refresh.map(str::to_string), method)
        }
    }
}

fn refresh_oauth_token(
    client_id: &str,
    client_secret: &str,
    refresh_token: &str,
    project_id: Option<&str>,
) -> Result<String, LimitsError> {
    let fp = format!("{client_id}\0{refresh_token}\0{}", project_id.unwrap_or(""));
    let now = now_ms();
    if let Ok(guard) = TOKEN_CACHE.lock()
        && let Some(c) = guard.as_ref()
        && c.fingerprint == fp
        && c.expires_at_ms > now + 60_000
    {
        return Ok(c.access_token.clone());
    }
    let (status, body) = http::post_form(
        "https://oauth2.googleapis.com/token",
        &[
            ("client_id", client_id),
            ("client_secret", client_secret),
            ("refresh_token", refresh_token),
            ("grant_type", "refresh_token"),
        ],
    )?;
    if status == 400 || status == 401 {
        return Err(LimitsError::TokenExpired);
    }
    if status != 200 {
        return Err(LimitsError::Http(status));
    }
    let json = http::parse_json_object(&body)?;
    let access = json.get("access_token").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or(LimitsError::BadResponse)?;
    let expires_in = json_f64(json.get("expires_in")).filter(|&v| v > 0.0).ok_or(LimitsError::BadResponse)?;
    if let Ok(mut guard) = TOKEN_CACHE.lock() {
        *guard = Some(RefreshedToken {
            fingerprint: fp,
            access_token: access.to_string(),
            expires_at_ms: now + (expires_in * 1000.0) as i64,
        });
    }
    Ok(access.to_string())
}

struct ResolvedAuth {
    access_token: String,
    project_id: Option<String>,
    auth_method: AuthMethod,
}

fn resolve_auth(paths: &Paths) -> Result<ResolvedAuth, LimitsError> {
    let now = now_ms();
    let mut saw_expired = false;
    for source in token_sources(paths) {
        if let Some(acp) = &source.acp_token
            && let Ok(raw) = std::fs::read_to_string(acp)
            && let Ok(v) = serde_json::from_str::<Value>(&raw)
            && let (Some(cid), Some(csec), Some(rtok)) = (
                v.get("client_id").and_then(Value::as_str).filter(|s| !s.is_empty()),
                v.get("client_secret").and_then(Value::as_str).filter(|s| !s.is_empty()),
                v.get("refresh_token").and_then(Value::as_str).filter(|s| !s.is_empty()),
            )
        {
            let project_id = v.get("project_id").and_then(Value::as_str).map(str::to_string);
            let access_token = refresh_oauth_token(cid, csec, rtok, project_id.as_deref())?;
            return Ok(ResolvedAuth { access_token, project_id, auth_method: source.auth_method });
        }
        if let Some(cli) = &source.cli_token
            && let Ok(raw) = std::fs::read_to_string(cli)
        {
            match parse_cli_token(&raw, now) {
                ParsedCliToken::Valid(access_token, method) => {
                    return Ok(ResolvedAuth {
                        access_token,
                        project_id: None,
                        auth_method: method.unwrap_or(source.auth_method),
                    });
                }
                ParsedCliToken::Expired(refresh, method) => {
                    if let Some(access_token) = refresh_cli_token(refresh.as_deref()) {
                        return Ok(ResolvedAuth {
                            access_token,
                            project_id: None,
                            auth_method: method.unwrap_or(source.auth_method),
                        });
                    }
                    saw_expired = true;
                }
                ParsedCliToken::Invalid => {}
            }
        }
    }

    #[cfg(target_os = "macos")]
    if let Some(secret) = http::keychain_password("gemini", Some("antigravity")) {
        let decoded = decode_go_keyring_secret(&secret);
        match parse_cli_token(&decoded, now) {
            ParsedCliToken::Valid(access_token, method) => {
                return Ok(ResolvedAuth {
                    access_token,
                    project_id: None,
                    auth_method: method.unwrap_or(AuthMethod::Personal),
                });
            }
            ParsedCliToken::Expired(refresh, method) => {
                if let Some(access_token) = refresh_cli_token(refresh.as_deref()) {
                    return Ok(ResolvedAuth {
                        access_token,
                        project_id: None,
                        auth_method: method.unwrap_or(AuthMethod::Personal),
                    });
                }
                saw_expired = true;
            }
            ParsedCliToken::Invalid => {}
        }
    }

    Err(if saw_expired { LimitsError::TokenExpired } else { LimitsError::NotConnected })
}

pub fn fetch(paths: &Paths) -> Result<ProviderLimits, LimitsError> {
    let auth = resolve_auth(paths)?;
    let body = match &auth.project_id {
        Some(p) if !p.is_empty() => serde_json::json!({ "project": p }).to_string(),
        _ => "{}".to_string(),
    };

    let (summary, sum_unauth, sum_err) = fetch_op("retrieveUserQuotaSummary", &auth, &body, parse_summary);
    if !summary.is_empty() {
        return Ok(ProviderLimits { provider: ProviderId::Antigravity, plan: None, windows: summary, fetched_at: now_ms() });
    }
    let (models, mod_unauth, mod_err) = fetch_op("fetchAvailableModels", &auth, &body, |j, _| parse_models(j));
    if !models.is_empty() {
        return Ok(ProviderLimits { provider: ProviderId::Antigravity, plan: None, windows: models, fetched_at: now_ms() });
    }
    if sum_unauth || mod_unauth {
        return Err(LimitsError::TokenExpired);
    }
    if let Some(e) = sum_err.or(mod_err) {
        return Err(e);
    }
    Err(LimitsError::BadResponse)
}

fn fetch_op(
    op: &str,
    auth: &ResolvedAuth,
    body: &str,
    parse: fn(&Value, i64) -> Vec<LimitWindow>,
) -> (Vec<LimitWindow>, bool, Option<LimitsError>) {
    let bearer = format!("Bearer {}", auth.access_token);
    let ua = user_agent();
    let mut windows = Vec::new();
    let mut seen = HashSet::new();
    let mut unauthorized = false;
    let mut last_err = None;

    for ep in auth.auth_method.endpoints() {
        let url = format!("{ep}/v1internal:{op}");
        let requested_at = now_ms();
        match http::post_json(&url, &[("Authorization", &bearer), ("User-Agent", ua)], body) {
            Ok((401 | 403, _)) => unauthorized = true,
            Ok((200, data)) => {
                if let Ok(json) = http::parse_json_object(&data) {
                    for w in parse(&json, requested_at) {
                        if seen.insert(w.id.clone()) {
                            windows.push(w);
                        }
                    }
                }
            }
            Ok((code, _)) => last_err = Some(LimitsError::Http(code)),
            Err(e) => last_err = Some(e),
        }
    }
    sort_windows(&mut windows);
    (windows, unauthorized, last_err)
}

pub(crate) fn parse_summary(json: &Value, requested_at: i64) -> Vec<LimitWindow> {
    let groups: Vec<(Option<&str>, &[Value])> = if let Some(gs) = json.get("groups").and_then(Value::as_array)
        && gs.iter().any(|g| g.get("buckets").and_then(Value::as_array).is_some_and(|b| !b.is_empty()))
    {
        gs.iter()
            .filter_map(|g| {
                let buckets = g.get("buckets").and_then(Value::as_array)?;
                Some((g.get("displayName").and_then(Value::as_str).map(str::trim), buckets.as_slice()))
            })
            .collect()
    } else if let Some(buckets) = json.get("buckets").and_then(Value::as_array) {
        vec![(None, buckets.as_slice())]
    } else {
        Vec::new()
    };

    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for (group_name, buckets) in groups {
        for b in buckets {
            if b.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let Some(bucket_id) = b.get("bucketId").and_then(Value::as_str).filter(|s| !s.is_empty()) else {
                continue;
            };
            let Some(rem) = json_f64(b.get("remainingFraction")).filter(|v| v.is_finite()) else {
                continue;
            };
            let window_kind = b.get("window").and_then(Value::as_str);
            let window_mins: Option<i64> = match window_kind {
                Some("5h") => Some(300),
                Some("weekly") => Some(10080),
                _ => None,
            };
            let raw_reset = b.get("resetTime").and_then(Value::as_str).and_then(parse_iso_ms);
            let has_desc = b.get("description").and_then(Value::as_str).is_some();
            let resets_at = match (rem == 1.0, has_desc, window_mins, raw_reset) {
                (true, false, Some(mins), Some(r)) if (r - requested_at - mins * 60_000).abs() <= 60_000 => None,
                _ => raw_reset,
            };
            let bucket_display = b.get("displayName").and_then(Value::as_str).map(str::trim);
            let (id, label, minor) = window_presentation(bucket_id, window_kind, bucket_display, group_name);
            if !seen.insert(id.clone()) {
                continue;
            }
            let percent = (1.0 - rem.clamp(0.0, 1.0)) * 100.0;
            out.push(LimitWindow { id, label, percent, resets_at, minor });
        }
    }
    sort_windows(&mut out);
    out
}

pub(crate) fn parse_models(json: &Value) -> Vec<LimitWindow> {
    let Some(models) = json.get("models").and_then(Value::as_object) else { return Vec::new() };
    let mut best: HashMap<String, LimitWindow> = HashMap::new();
    for (model_id, raw) in models {
        let provider = raw.get("modelProvider").and_then(Value::as_str);
        let family = if provider == Some("MODEL_PROVIDER_GOOGLE") || model_id.starts_with("gemini-") {
            "Gemini"
        } else if provider == Some("MODEL_PROVIDER_ANTHROPIC") || model_id.starts_with("claude-") {
            "Claude"
        } else if provider == Some("MODEL_PROVIDER_OPENAI") || model_id.starts_with("gpt-") {
            "GPT"
        } else {
            continue;
        };
        for (suffix, key) in [("quota", "quotaInfo"), ("weekly", "weeklyQuotaInfo")] {
            let Some(quota) = raw.get(key) else { continue };
            let Some(rem) = json_f64(quota.get("remainingFraction")).filter(|v| v.is_finite()) else { continue };
            let id = if family == "Gemini" {
                if suffix == "weekly" { "week".to_string() } else { "quota".to_string() }
            } else {
                format!("{}-{suffix}", family.to_lowercase())
            };
            let label = if family == "Gemini" {
                if suffix == "weekly" { "Week".to_string() } else { "Quota".to_string() }
            } else if suffix == "weekly" {
                format!("{family} Week")
            } else {
                family.to_string()
            };
            let percent = (1.0 - rem.clamp(0.0, 1.0)) * 100.0;
            let resets_at = quota.get("resetTime").and_then(Value::as_str).and_then(parse_iso_ms);
            let candidate = LimitWindow { id: id.clone(), label, percent, resets_at, minor: family != "Gemini" };
            if best.get(&id).is_some_and(|prev| prev.percent >= candidate.percent) {
                continue;
            }
            best.insert(id, candidate);
        }
    }
    let mut out: Vec<LimitWindow> = best.into_values().collect();
    sort_windows(&mut out);
    out
}

fn window_presentation(
    bucket_id: &str,
    window: Option<&str>,
    bucket_display: Option<&str>,
    group_display: Option<&str>,
) -> (String, String, bool) {
    if bucket_id == "gemini-5h" {
        return ("5h".into(), "5h".into(), false);
    }
    if bucket_id == "gemini-weekly" {
        return ("week".into(), "Week".into(), false);
    }
    if bucket_id == "3p-5h" {
        return (bucket_id.into(), "3P 5h".into(), true);
    }
    if bucket_id == "3p-weekly" {
        return (bucket_id.into(), "3P Week".into(), true);
    }
    let suffix = match window {
        Some("weekly") => "Week",
        Some("5h") => "5h",
        _ => bucket_display.filter(|s| !s.is_empty()).unwrap_or("Quota"),
    };
    if bucket_id.starts_with("gemini-argon-") {
        return (bucket_id.into(), "Argon".into(), true);
    }
    if bucket_id.starts_with("gemini-carbon-") {
        return (bucket_id.into(), "Carbon".into(), true);
    }
    if bucket_id.starts_with("gemini-") {
        return (bucket_id.into(), suffix.into(), false);
    }
    if bucket_id.starts_with("3p-") {
        return (bucket_id.into(), format!("3P {suffix}"), true);
    }
    let family = group_display.filter(|s| !s.is_empty()).unwrap_or(bucket_id);
    (bucket_id.into(), format!("{family} {suffix}"), true)
}

fn sort_windows(windows: &mut [LimitWindow]) {
    let rank = |w: &LimitWindow| -> (u8, u8, String) {
        if w.id == "5h" {
            (0, 0, w.id.clone())
        } else if w.id == "quota" {
            (0, 1, w.id.clone())
        } else if w.id == "week" {
            (0, 2, w.id.clone())
        } else if !w.minor {
            (1, 0, w.id.clone())
        } else if w.id == "3p-5h" {
            (2, 0, w.id.clone())
        } else if w.id == "3p-weekly" {
            (2, 1, w.id.clone())
        } else {
            (3, 0, w.id.clone())
        }
    };
    windows.sort_by_key(rank);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_quota_summary() {
        let req_at = parse_iso_ms("2026-11-22T11:23:29Z").unwrap();
        let body = json!({
            "groups": [
                {
                    "displayName": "Gemini Models",
                    "buckets": [
                        {"bucketId": "gemini-weekly", "window": "weekly", "resetTime": "2026-11-29T11:17:09Z",
                         "description": "used some", "remainingFraction": 0.97},
                        {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-11-22T16:17:09Z",
                         "description": "used some", "remainingFraction": 0.91}
                    ]
                },
                {
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        {"bucketId": "3p-5h", "window": "5h", "resetTime": "2026-11-22T16:23:29Z", "remainingFraction": 1}
                    ]
                },
                {
                    "displayName": "Gemini 4 Argon",
                    "buckets": [
                        {"bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "resetTime": "2026-11-29T11:23:29Z", "remainingFraction": 1}
                    ]
                }
            ]
        });
        let w = parse_summary(&body, req_at);
        let ids: Vec<_> = w.iter().map(|x| (x.id.as_str(), x.label.as_str(), x.minor)).collect();
        assert_eq!(
            ids,
            [
                ("5h", "5h", false),
                ("week", "Week", false),
                ("3p-5h", "3P 5h", true),
                ("gemini-argon-wtu-weekly", "Argon", true),
            ]
        );
        assert!((w[0].percent - 9.0).abs() < 1e-6);
        assert!(w[0].resets_at.is_some());
        // Unused 3p-5h has synthetic resetTime == req_at + 5h -> hidden.
        assert_eq!(w[2].resets_at, None);
    }

    #[test]
    fn decodes_go_keyring_prefixes() {
        assert_eq!(decode_go_keyring_secret("go-keyring-base64:aGVsbG8="), "hello");
        assert_eq!(decode_go_keyring_secret("go-keyring-encoded:68656c6c6f"), "hello");
        assert_eq!(decode_go_keyring_secret("plain"), "plain");
    }

    #[test]
    fn expired_cli_token_keeps_refresh_token() {
        let token = |expiry: &str| {
            format!(r#"{{"token":{{"access_token":"a","refresh_token":"r","expiry":"{expiry}"}},"auth_method":"consumer"}}"#)
        };
        let now = parse_iso_ms("2027-01-15T08:00:00Z").unwrap();
        assert_eq!(
            parse_cli_token(&token("2027-01-15T09:00:00Z"), now),
            ParsedCliToken::Valid("a".into(), Some(AuthMethod::Personal))
        );
        assert_eq!(
            parse_cli_token(&token("2027-01-15T07:00:00Z"), now),
            ParsedCliToken::Expired(Some("r".into()), Some(AuthMethod::Personal))
        );
        assert_eq!(
            parse_cli_token(r#"{"token":{"access_token":"a"}}"#, now),
            ParsedCliToken::Expired(None, None)
        );
    }
}
