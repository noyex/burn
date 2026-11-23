//! Blocking HTTP helper and small JSON/time helpers shared by the fetchers.

use crate::model::LimitsError;
use serde_json::Value;
use std::sync::LazyLock;
use std::time::Duration;

static AGENT: LazyLock<ureq::Agent> = LazyLock::new(|| {
    let config =
        ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(15))).http_status_as_error(false).build();
    ureq::Agent::new_with_config(config)
});

fn read(
    result: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
    limit: u64,
) -> Result<(u16, Vec<u8>), LimitsError> {
    let mut resp = result.map_err(|e| LimitsError::Network(e.to_string()))?;
    let status = resp.status().as_u16();
    let body =
        resp.body_mut().with_config().limit(limit).read_to_vec().map_err(|e| LimitsError::Network(e.to_string()))?;
    Ok((status, body))
}

/// GET with headers. Returns the status and body; non-2xx is not an error.
pub fn get(url: &str, headers: &[(&str, &str)]) -> Result<(u16, Vec<u8>), LimitsError> {
    get_limited(url, headers, 10 * 1024 * 1024)
}

/// GET that accepts a body of up to `limit` bytes.
pub fn get_limited(url: &str, headers: &[(&str, &str)], limit: u64) -> Result<(u16, Vec<u8>), LimitsError> {
    let mut req = AGENT.get(url);
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    read(req.call(), limit)
}

/// POST with headers and a JSON body.
pub fn post_json(url: &str, headers: &[(&str, &str)], body: &str) -> Result<(u16, Vec<u8>), LimitsError> {
    let mut req = AGENT.post(url).header("Content-Type", "application/json");
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    read(req.send(body), 10 * 1024 * 1024)
}

/// POST application/x-www-form-urlencoded.
pub fn post_form(url: &str, params: &[(&str, &str)]) -> Result<(u16, Vec<u8>), LimitsError> {
    read(AGENT.post(url).send_form(params.iter().copied()), 10 * 1024 * 1024)
}

pub fn parse_json_object(body: &[u8]) -> Result<Value, LimitsError> {
    match serde_json::from_slice::<Value>(body) {
        Ok(v) if v.is_object() => Ok(v),
        _ => Err(LimitsError::BadResponse),
    }
}

/// JSON number that may arrive as a number or a numeric string.
pub fn json_f64(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// ISO 8601 with or without fractional seconds, as epoch milliseconds.
pub fn parse_iso_ms(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis())
}

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// Like Swift's `capitalized`: first letter of each word upper, the rest lower. Anything but a letter or an
/// apostrophe ends a word ("pro_plus" -> "Pro_Plus", "x1y" -> "X1Y", "o'neil" -> "O'neil").
pub fn capitalized(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut start = true;
    for c in s.chars() {
        if c.is_alphabetic() || c == '\'' {
            if start {
                out.extend(c.to_uppercase());
            } else {
                out.extend(c.to_lowercase());
            }
            start = false;
        } else {
            out.push(c);
            start = true;
        }
    }
    out
}

/// Runs the macOS `security` tool and returns trimmed stdout on success.
#[cfg(target_os = "macos")]
pub fn keychain_password(service: &str, account: Option<&str>) -> Option<String> {
    let mut cmd = std::process::Command::new("/usr/bin/security");
    cmd.args(["find-generic-password", "-s", service]);
    if let Some(a) = account {
        cmd.args(["-a", a]);
    }
    cmd.arg("-w").stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    let out = cmd.output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

#[cfg(target_os = "macos")]
pub fn keychain_item_exists(service: &str, account: Option<&str>) -> bool {
    let mut cmd = std::process::Command::new("/usr/bin/security");
    cmd.args(["find-generic-password", "-s", service]);
    if let Some(a) = account {
        cmd.args(["-a", a]);
    }
    cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn dates_and_numbers() {
        assert_eq!(parse_iso_ms("2026-01-01T00:00:00Z"), Some(1_767_225_600_000));
        assert_eq!(parse_iso_ms("2026-01-01T00:00:00.500+00:00"), Some(1_767_225_600_500));
        assert_eq!(parse_iso_ms("nope"), None);
        assert_eq!(json_f64(Some(&json!("12.5"))), Some(12.5));
        assert_eq!(json_f64(Some(&json!(3))), Some(3.0));
        assert_eq!(json_f64(Some(&json!(null))), None);
        assert_eq!(capitalized("pro_plus max"), "Pro_Plus Max");
        assert_eq!(capitalized("x1y o'neil MAX"), "X1Y O'neil Max");
    }
}
