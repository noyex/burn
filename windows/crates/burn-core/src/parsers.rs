//! Ports of `UsageParsers.swift` (itself a port of T3 Code's usage readers). Per-record tokens,
//! speed and reported cost must stay identical to the Swift version.

use crate::rates::ModelRates;
use chrono::{DateTime, Local};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Speed {
    Standard,
    Fast,
    Ultrafast,
}

impl Speed {
    /// Index used by T3's scan cache.
    pub const CACHE_ORDER: [Speed; 3] = [Speed::Standard, Speed::Fast, Speed::Ultrafast];

    pub fn as_str(self) -> &'static str {
        match self {
            Speed::Standard => "standard",
            Speed::Fast => "fast",
            Speed::Ultrafast => "ultrafast",
        }
    }

    pub fn parse(s: &str) -> Option<Speed> {
        Self::CACHE_ORDER.into_iter().find(|v| v.as_str() == s)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct TokenTotals {
    pub uncached: i64,
    pub cached: i64,
    pub cache_creation: i64,
    pub output: i64,
    pub reasoning: i64,
}

impl TokenTotals {
    /// Reasoning is already inside output, so it is not part of the total.
    pub fn total(&self) -> i64 {
        self.uncached + self.cached + self.cache_creation + self.output
    }
}

/// One parsed usage record, before pricing.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageRecord {
    pub provider: String,
    pub ts_ms: i64,
    pub model: String,
    pub rate_model: Option<String>,
    pub session_id: String,
    pub project: Option<String>,
    pub totals: TokenTotals,
    pub reported_cost: Option<f64>,
    pub speed: Speed,
    pub dedupe_key: Option<String>,
    /// Codex turn whose service tier is unknown (resolved later from T3's database).
    pub tier_turn: Option<String>,
}

/// One usage record, ready to be written to the store.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageRow {
    pub id: String,
    pub provider: String,
    pub model: String,
    pub ts_ms: i64,
    /// Local time, `%Y-%m-%dT%H:%M:%S`.
    pub ts: String,
    /// Local date, `YYYY-MM-DD`.
    pub day: String,
    pub session: Option<String>,
    pub project: Option<String>,
    pub totals: TokenTotals,
    pub speed: Speed,
    pub reported_cost: Option<f64>,
    pub rate_model: Option<String>,
    pub tier_turn: Option<String>,
    pub cost: f64,
    pub origin: String,
    pub source: String,
}

impl UsageRow {
    pub fn new(
        r: &UsageRecord,
        id: String,
        project: Option<&str>,
        origin: &str,
        source: &str,
        rates: &ModelRates,
    ) -> UsageRow {
        let cost = rates.cost(
            &r.model,
            r.rate_model.as_deref(),
            r.speed,
            r.totals.uncached,
            r.totals.cached,
            r.totals.cache_creation,
            r.totals.output,
            r.reported_cost,
        );
        // Local time, like the reference importer.
        let ts = DateTime::from_timestamp(r.ts_ms / 1000, 0)
            .map(|d| d.with_timezone(&Local).format("%Y-%m-%dT%H:%M:%S").to_string())
            .unwrap_or_default();
        let day: String = ts.chars().take(10).collect();
        UsageRow {
            id,
            provider: r.provider.clone(),
            model: r.model.clone(),
            ts_ms: r.ts_ms,
            ts,
            day,
            session: if r.session_id.is_empty() { None } else { Some(r.session_id.clone()) },
            project: r.project.clone().or_else(|| project.map(str::to_string)),
            totals: r.totals,
            speed: r.speed,
            reported_cost: r.reported_cost,
            rate_model: r.rate_model.clone(),
            tier_turn: r.tier_turn.clone(),
            cost,
            origin: origin.to_string(),
            source: source.to_string(),
        }
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date; `m` is 1...12.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// ISO-8601 to epoch ms, like the Swift `isoToMs`.
pub fn iso_to_ms(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    // Empty ranges read as 0, like the Swift helper.
    let n = |a: usize, e: usize| -> Option<i64> {
        let mut v = 0i64;
        for &c in &b[a..e] {
            if !c.is_ascii_digit() {
                return None;
            }
            v = v * 10 + (c - b'0') as i64;
        }
        Some(v)
    };
    let y = n(0, 4)?;
    let mo = n(5, 7)?;
    let d = n(8, 10)?;
    let h = n(11, 13)?;
    let mi = n(14, 16)?;
    let sec = n(17, 19)?;
    let mut i = 19;
    let mut millis = 0i64;
    if i < b.len() && b[i] == b'.' {
        i += 1;
        let mut digits = 0;
        while i < b.len() && b[i].is_ascii_digit() {
            if digits < 3 {
                millis = millis * 10 + (b[i] - b'0') as i64;
                digits += 1;
            }
            i += 1;
        }
        while digits < 3 {
            millis *= 10;
            digits += 1;
        }
    }
    let mut offset = 0i64;
    if i < b.len()
        && (b[i] == b'+' || b[i] == b'-')
        && let Some(oh) = n(i + 1, (i + 3).min(b.len()))
    {
        let om = if i + 6 <= b.len() { n(i + 4, i + 6).unwrap_or(0) } else { 0 };
        offset = (oh * 3600 + om * 60) * if b[i] == b'-' { -1 } else { 1 };
    }
    // timegm normalizes out-of-range months and days.
    let m0 = mo - 1;
    let year = y + m0.div_euclid(12);
    let month = m0.rem_euclid(12) + 1;
    let days = days_from_civil(year, month, 1) + (d - 1);
    let secs = days * 86400 + h * 3600 + mi * 60 + sec - offset;
    Some(secs * 1000 + millis)
}

// MARK: JSON helpers

/// JSON number (not a boolean), finite.
fn num(v: Option<&Value>) -> Option<f64> {
    match v {
        Some(Value::Number(n)) => n.as_f64().filter(|d| d.is_finite()),
        _ => None,
    }
}

const MAX_INTEGER: f64 = 1e15;

fn to_i64(d: f64) -> Option<i64> {
    if d.abs() <= MAX_INTEGER { Some(d as i64) } else { None }
}

fn str_of(v: Option<&Value>) -> Option<&str> {
    match v {
        Some(Value::String(s)) => Some(s),
        _ => None,
    }
}

fn obj(v: Option<&Value>) -> Option<&Map<String, Value>> {
    match v {
        Some(Value::Object(m)) => Some(m),
        _ => None,
    }
}

fn timestamp(v: Option<&Value>) -> Option<i64> {
    str_of(v).and_then(iso_to_ms)
}

/// Calls `body` with the JSON object of every line that contains at least one needle.
fn scan_lines(data: &[u8], needles: &[&str], mut body: impl FnMut(&Map<String, Value>)) {
    let finders: Vec<memchr::memmem::Finder> =
        needles.iter().map(|n| memchr::memmem::Finder::new(n.as_bytes())).collect();
    let mut pos = 0;
    while pos < data.len() {
        let rest = &data[pos..];
        let len = memchr::memchr(b'\n', rest).unwrap_or(rest.len());
        let line = &rest[..len];
        if len > 2
            && finders.iter().any(|f| f.find(line).is_some())
            && let Ok(Value::Object(m)) = serde_json::from_slice::<Value>(line)
        {
            body(&m);
        }
        pos += len + 1;
    }
}

// MARK: Claude

/// T3's `tokenCount`: positive finite numbers, truncated.
fn token_count(v: Option<&Value>) -> i64 {
    match num(v) {
        Some(d) if d > 0.0 => to_i64(d.trunc()).unwrap_or(0),
        _ => 0,
    }
}

fn claude_record(d: &Map<String, Value>) -> Option<UsageRecord> {
    if str_of(d.get("type")) != Some("assistant") {
        return None;
    }
    let msg = obj(d.get("message"))?;
    let u = obj(msg.get("usage"))?;
    let ms = timestamp(d.get("timestamp"))?;
    let model = str_of(msg.get("model"))?;
    if model.is_empty() || model == "<synthetic>" {
        return None;
    }
    let mid = str_of(msg.get("id"));
    let rid = str_of(d.get("requestId"));
    let key = if mid.is_none() && rid.is_none() {
        None
    } else {
        Some(format!("{}:{}", mid.unwrap_or(""), rid.unwrap_or("")))
    };
    Some(UsageRecord {
        provider: "claude".into(),
        ts_ms: ms,
        model: model.to_string(),
        rate_model: None,
        session_id: str_of(d.get("sessionId")).unwrap_or("").to_string(),
        project: str_of(d.get("cwd")).map(str::to_string),
        totals: TokenTotals {
            uncached: token_count(u.get("input_tokens")),
            cached: token_count(u.get("cache_read_input_tokens")),
            cache_creation: token_count(u.get("cache_creation_input_tokens")),
            output: token_count(u.get("output_tokens")),
            reasoning: 0,
        },
        reported_cost: num(d.get("costUSD")),
        speed: if str_of(u.get("speed")) == Some("fast") { Speed::Fast } else { Speed::Standard },
        dedupe_key: key,
        tier_turn: None,
    })
}

/// Records of one Claude transcript, in file order, repeats of a `dedupe_key` dropped (first kept).
pub fn parse_claude_records(path: &Path) -> io::Result<Vec<UsageRecord>> {
    let data = std::fs::read(path)?;
    let mut out = Vec::new();
    scan_lines(&data, &["\"usage\""], |d| {
        if let Some(r) = claude_record(d) {
            out.push(r);
        }
    });
    Ok(dedupe_within_file(out))
}

/// One `seen` set over the whole file, first occurrence wins.
pub fn dedupe_within_file(records: Vec<UsageRecord>) -> Vec<UsageRecord> {
    let mut seen: HashSet<String> = HashSet::new();
    records
        .into_iter()
        .filter(|r| match &r.dedupe_key {
            None => true,
            Some(k) => seen.insert(k.clone()),
        })
        .collect()
}

// MARK: Codex

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CodexUsage {
    input: i64,
    cached: i64,
    cache_write: i64,
    output: i64,
    reasoning: i64,
    total: i64,
}

impl CodexUsage {
    fn is_valid(&self) -> bool {
        self.cached + self.cache_write <= self.input
            && self.reasoning <= self.output
            && self.total >= self.input + self.output
    }

    /// `readCodexTokenUsage`.
    fn read(value: Option<&Value>) -> Option<CodexUsage> {
        let raw = obj(value)?;
        // Missing -> default; present but invalid -> the whole read fails.
        let field = |k: &str| -> Option<Option<i64>> {
            match raw.get(k) {
                None => Some(None),
                Some(v) => {
                    let d = num(Some(v))?;
                    if d >= 0.0 && d == d.round() { to_i64(d).map(Some) } else { None }
                }
            }
        };
        let i = num(raw.get("input_tokens"))?;
        let o = num(raw.get("output_tokens"))?;
        if !(i >= 0.0 && o >= 0.0 && i == i.round() && o == o.round() && i <= MAX_INTEGER && o <= MAX_INTEGER) {
            return None;
        }
        let c = field("cached_input_tokens")?;
        let w = field("cache_write_input_tokens")?;
        let r = field("reasoning_output_tokens")?;
        let t = field("total_tokens")?;
        let (i, o) = (i as i64, o as i64);
        let u = CodexUsage {
            input: i,
            cached: c.unwrap_or(0),
            cache_write: w.unwrap_or(0),
            output: o,
            reasoning: r.unwrap_or(0),
            total: t.unwrap_or(i + o),
        };
        u.is_valid().then_some(u)
    }

    /// `advanceCodexUsage`.
    fn advance(prev: Option<CodexUsage>, last: CodexUsage) -> Option<CodexUsage> {
        let p = prev.unwrap_or(CodexUsage { input: 0, cached: 0, cache_write: 0, output: 0, reasoning: 0, total: 0 });
        let u = CodexUsage {
            input: p.input + last.input,
            cached: p.cached + last.cached,
            cache_write: p.cache_write + last.cache_write,
            output: p.output + last.output,
            reasoning: p.reasoning + last.reasoning,
            total: p.total + last.total,
        };
        u.is_valid().then_some(u)
    }
}

#[derive(Default)]
struct CodexScanState {
    model: String,
    speed: Option<Speed>,
    session_id: String,
    model_provider: String,
    turn_id: String,
    project: Option<String>,
    last_signature: Option<CodexUsage>,
    last_cumulative: Option<CodexUsage>,
    saw_session_meta: bool,
    saw_thread_settings: bool,
    suppressing_fork_copies: bool,
    fork_copy_anchor_ms: i64,
}

const FORK_COPY_MAX_GAP_MS: i64 = 1000;

fn is_forked_session_meta(p: &Map<String, Value>) -> bool {
    if matches!(p.get("forked_from_id"), Some(Value::String(_))) {
        return true;
    }
    let parent = obj(p.get("source"))
        .and_then(|s| obj(s.get("subagent")))
        .and_then(|s| obj(s.get("thread_spawn")))
        .and_then(|s| s.get("parent_thread_id"));
    matches!(parent, Some(Value::String(_)))
}

fn codex_speed(tier: Option<&Value>) -> Speed {
    match str_of(tier) {
        Some("priority") | Some("fast") => Speed::Fast,
        Some("ultrafast") => Speed::Ultrafast,
        _ => Speed::Standard,
    }
}

/// `parseCodexRecord`: one line of a Codex rollout, updating `s`.
fn codex_record(rec: &Map<String, Value>, s: &mut CodexScanState) -> Option<UsageRecord> {
    let payload = obj(rec.get("payload"))?;
    let payload_type = str_of(payload.get("type"));
    let ty = str_of(rec.get("type"));
    if ty == Some("session_meta") {
        if s.saw_session_meta {
            return None;
        }
        s.saw_session_meta = true;
        let idv = match payload.get("id") {
            None | Some(Value::Null) => payload.get("session_id"),
            other => other,
        };
        if let Some(id) = str_of(idv) {
            s.session_id = id.to_string();
        }
        s.project = str_of(payload.get("cwd")).map(str::to_string);
        if let Some(mp) = str_of(payload.get("model_provider")) {
            s.model_provider = mp.to_string();
        }
        if let Some(ms) = timestamp(rec.get("timestamp"))
            && is_forked_session_meta(payload)
        {
            s.suppressing_fork_copies = true;
            s.fork_copy_anchor_ms = ms;
        }
        return None;
    }
    if ty == Some("turn_context") {
        let model = str_of(payload.get("model"));
        if let Some(m) = model {
            s.model = m.to_string();
        }
        s.turn_id = match (str_of(payload.get("turn_id")), model) {
            (Some(t), Some(m)) if !m.is_empty() => t.to_string(),
            _ => String::new(),
        };
        return None;
    }
    if payload_type == Some("thread_settings_applied") {
        s.saw_thread_settings = true;
        if let Some(settings) = obj(payload.get("thread_settings")) {
            s.speed = Some(codex_speed(settings.get("service_tier")));
        }
        return None;
    }
    if payload_type != Some("token_count") {
        return None;
    }
    let info = obj(payload.get("info"))?;
    let ts = timestamp(rec.get("timestamp"))?;
    if s.model.is_empty() {
        return None;
    }
    let last = CodexUsage::read(info.get("last_token_usage"));
    let raw_cum = info.get("total_token_usage");
    let has_cum = !matches!(raw_cum, None | Some(Value::Null));
    let cum = if has_cum { CodexUsage::read(raw_cum) } else { None };

    if s.suppressing_fork_copies {
        if ts - s.fork_copy_anchor_ms < FORK_COPY_MAX_GAP_MS {
            s.fork_copy_anchor_ms = ts;
            if let Some(c) = cum {
                s.last_cumulative = Some(c);
            } else if !has_cum
                && let Some(l) = last
                && Some(l) != s.last_signature
            {
                s.last_cumulative = CodexUsage::advance(s.last_cumulative, l);
            }
            s.last_signature = last;
            return None;
        }
        s.suppressing_fork_copies = false;
        s.last_signature = None;
    }
    let previous = s.last_cumulative;
    if let Some(c) = cum {
        s.last_cumulative = Some(c);
    }
    let last = last?;
    if has_cum && cum.is_none() {
        return None;
    }
    if let Some(c) = cum {
        if last.input + last.output == 0
            && c.input + c.output == 0
            && num(info.get("model_context_window")) == Some(c.total as f64)
        {
            s.last_signature = None;
            return None;
        }
        if Some(c) == previous {
            return None;
        }
    }
    if last.total != last.input + last.output {
        return None;
    }
    if let Some(c) = cum {
        let zero = CodexUsage { input: 0, cached: 0, cache_write: 0, output: 0, reasoning: 0, total: 0 };
        let p = previous.unwrap_or(zero);
        if c.input - p.input != last.input
            || c.cached - p.cached != last.cached
            || c.cache_write - p.cache_write != last.cache_write
            || c.output - p.output != last.output
            || c.reasoning - p.reasoning != last.reasoning
            || c.total - p.total != last.total
        {
            return None;
        }
    } else {
        if Some(last) == s.last_signature {
            return None;
        }
        s.last_cumulative = Some(CodexUsage::advance(previous, last)?);
    }
    s.last_signature = Some(last);
    let totals = TokenTotals {
        uncached: last.input - last.cached - last.cache_write,
        cached: last.cached,
        cache_creation: last.cache_write,
        output: last.output,
        reasoning: last.reasoning,
    };
    if totals.total() == 0 {
        return None;
    }
    let unresolved =
        !s.saw_thread_settings && s.model_provider == "openai" && !s.session_id.is_empty() && !s.turn_id.is_empty();
    Some(UsageRecord {
        provider: "codex".into(),
        ts_ms: ts,
        model: s.model.clone(),
        rate_model: None,
        session_id: s.session_id.clone(),
        project: s.project.clone(),
        totals,
        reported_cost: None,
        speed: s.speed.unwrap_or(Speed::Standard),
        dedupe_key: None,
        tier_turn: if unresolved { Some(s.turn_id.clone()) } else { None },
    })
}

pub fn parse_codex_records(path: &Path) -> io::Result<Vec<UsageRecord>> {
    let data = std::fs::read(path)?;
    let mut state = CodexScanState::default();
    let mut out = Vec::new();
    scan_lines(
        &data,
        &["\"token_count\"", "\"turn_context\"", "\"thread_settings_applied\"", "\"session_meta\""],
        |d| {
            if let Some(r) = codex_record(d, &mut state) {
                out.push(r);
            }
        },
    );
    Ok(out)
}

// MARK: Row identity

/// Store ids that reproduce T3's dedupe: Claude by `messageId:requestId`; Codex sessions shared between files by
/// (session, timestamp, model, totals) plus the occurrence within the file. Records T3 never dedupes get a unique id.
pub fn make_rows(
    records: &[UsageRecord],
    path: &str,
    origin: &str,
    project: Option<&str>,
    rates: &ModelRates,
) -> Vec<UsageRow> {
    let mut occurrences: HashMap<String, usize> = HashMap::new();
    let mut rows = Vec::with_capacity(records.len());
    for (i, r) in records.iter().enumerate() {
        let id = if r.provider == "codex" {
            if r.session_id.is_empty() {
                format!("codex:{path}#{i}")
            } else {
                let t = &r.totals;
                let key = format!(
                    "codex:{}:{}:{}:{}:{}:{}:{}:{}",
                    r.session_id, r.ts_ms, r.model, t.uncached, t.cached, t.cache_creation, t.output, t.reasoning
                );
                let n = occurrences.entry(key.clone()).or_insert(0);
                *n += 1;
                format!("{key}#{n}")
            }
        } else {
            r.dedupe_key.clone().unwrap_or_else(|| format!("{}:{path}#{i}", r.provider))
        };
        rows.push(UsageRow::new(r, id, project, origin, path, rates));
    }
    rows
}

// MARK: T3 scan cache

/// One transcript's records as T3 saved them.
#[derive(Clone, Debug)]
pub struct T3CacheFile {
    pub path: String,
    pub provider: String,
    pub size: i64,
    pub records: Vec<UsageRecord>,
}

/// Cache format version from a file name (`usage-scan-cache-v7.json` -> 7, unversioned -> 0).
pub fn t3_cache_version(name: &str) -> i64 {
    let (Some(a), Some(b)) = (name.find("-v"), name.find(".json")) else { return 0 };
    if a + 2 > b {
        return 0;
    }
    name[a + 2..b].parse::<i64>().unwrap_or(0)
}

fn to_index(v: Option<&Value>) -> Option<usize> {
    num(v).and_then(to_i64).and_then(|i| usize::try_from(i).ok())
}

fn decode_t3_rows(
    rows: &[Value],
    provider: &str,
    src: &str,
    version: f64,
    models: &[String],
    sessions: &[String],
) -> Option<Vec<UsageRecord>> {
    let mut out = Vec::new();
    for row in rows {
        let Value::Array(r) = row else { continue };
        // [ts_ms, model, session, uncached, cached, cacheCreation, output, reasoning, dedupeKey, reportedCost, speed, rateModel, tierTurn?]
        if r.len() < 11 {
            return None;
        }
        let ts = num(r.first()).and_then(to_i64)?;
        let mi = to_index(r.get(1)).filter(|&i| i < models.len())?;
        let u = num(r.get(3)).and_then(to_i64)?;
        let c = num(r.get(4)).and_then(to_i64)?;
        let w = num(r.get(5)).and_then(to_i64)?;
        let o = num(r.get(6)).and_then(to_i64)?;
        let re = num(r.get(7)).and_then(to_i64)?;
        let si = to_index(r.get(10)).filter(|&i| i < Speed::CACHE_ORDER.len())?;
        let mut rate_model = None;
        if r.len() > 11 && matches!(r[11], Value::Number(_) | Value::Bool(_)) {
            let ri = to_index(r.get(11)).filter(|&i| i < models.len())?;
            rate_model = Some(models[ri].clone());
        }
        let mut tier = None;
        if version >= 7.0 && r.len() > 12 && !r[12].is_null() {
            let Value::String(t) = &r[12] else { return None };
            tier = Some(t.clone());
        }
        let model = &models[mi];
        if provider == "claude" && model == "<synthetic>" {
            continue;
        }
        let sess = to_index(r.get(2)).filter(|&i| i < sessions.len()).map(|i| sessions[i].clone()).unwrap_or_default();
        let project = if provider == "claude" {
            Some(
                Path::new(src)
                    .parent()
                    .and_then(|p| p.file_name())
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default(),
            )
        } else {
            None
        };
        out.push(UsageRecord {
            provider: provider.to_string(),
            ts_ms: ts,
            model: model.clone(),
            rate_model,
            session_id: sess,
            project,
            totals: TokenTotals { uncached: u, cached: c, cache_creation: w, output: o, reasoning: re },
            reported_cost: num(r.get(9)),
            speed: Speed::CACHE_ORDER[si],
            dedupe_key: str_of(r.get(8)).map(str::to_string),
            tier_turn: tier,
        });
    }
    Some(out)
}

fn string_array(v: Option<&Value>) -> Option<Vec<String>> {
    match v {
        Some(Value::Array(a)) => {
            a.iter().map(|x| if let Value::String(s) = x { Some(s.clone()) } else { None }).collect()
        }
        _ => None,
    }
}

/// Decodes T3's usage-scan-cache*.json (`decodeScanCache`). Entries that fail validation are skipped, like T3 does.
pub fn parse_t3_cache(path: &Path) -> io::Result<Vec<T3CacheFile>> {
    let data = std::fs::read(path)?;
    let root: Value = serde_json::from_slice(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let Value::Object(d) = &root else {
        return Ok(vec![]);
    };
    let Some(version) = num(d.get("version")).filter(|v| (4.0..=17.0).contains(v)) else { return Ok(vec![]) };
    let (Some(models), Some(sessions), Some(files)) =
        (string_array(d.get("models")), string_array(d.get("sessions")), obj(d.get("files")))
    else {
        return Ok(vec![]);
    };

    let mut out = Vec::new();
    let sorted: BTreeMap<&String, &Value> = files.iter().collect();
    for (src, e) in sorted {
        let Value::Object(entry) = e else { continue };
        let Some(provider) =
            str_of(entry.get("p")).filter(|p| *p == "claude" || *p == "codex" || *p == "antigravity")
        else {
            continue;
        };
        if num(entry.get("s")).is_none() || num(entry.get("m")).is_none() {
            continue;
        }
        let (Some(Value::Array(r)), Some(Value::Array(t))) = (entry.get("r"), entry.get("t")) else { continue };
        let (Some(rec), Some(tail)) = (
            decode_t3_rows(r, provider, src, version, &models, &sessions),
            decode_t3_rows(t, provider, src, version, &models, &sessions),
        ) else {
            continue;
        };
        // `records` and `tailRecords` are deduped with one shared set.
        let mut merged = rec;
        merged.extend(tail);
        if provider == "claude" {
            merged = dedupe_within_file(merged);
        }
        out.push(T3CacheFile {
            path: src.clone(),
            provider: provider.to_string(),
            size: num(entry.get("s")).and_then(to_i64).unwrap_or(-1),
            records: merged,
        });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tmp_file(tag: &str, content: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("burn-parsers-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join(format!("{tag}.jsonl"));
        std::fs::write(&p, content).unwrap();
        p
    }

    #[test]
    fn iso_variants() {
        assert_eq!(iso_to_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso_to_ms("1970-01-01T00:00:00"), Some(0));
        assert_eq!(iso_to_ms("2026-01-02T03:04:05.678Z"), Some(1_767_323_045_678));
        assert_eq!(iso_to_ms("2026-01-02T03:04:05.6789123Z"), Some(1_767_323_045_678));
        assert_eq!(iso_to_ms("2026-01-02T03:04:05.5Z"), Some(1_767_323_045_500));
        assert_eq!(iso_to_ms("2026-01-02T03:04:05+02:00"), Some(1_767_323_045_000 - 7_200_000));
        assert_eq!(iso_to_ms("2026-01-02T03:04:05-05:30"), Some(1_767_323_045_000 + 19_800_000));
        assert_eq!(iso_to_ms("2026-01-02T03:04"), None);
        assert_eq!(iso_to_ms("2026-0x-02T03:04:05Z"), None);
        // timegm normalizes: month 13 is January of next year, day 32 of January is Feb 1.
        assert_eq!(iso_to_ms("2025-13-01T00:00:00Z"), iso_to_ms("2026-01-01T00:00:00Z"));
        assert_eq!(iso_to_ms("2026-01-32T00:00:00Z"), iso_to_ms("2026-02-01T00:00:00Z"));
        assert_eq!(iso_to_ms("2026-00-01T00:00:00Z"), iso_to_ms("2025-12-01T00:00:00Z"));
    }

    #[test]
    fn claude_dedupe_and_synthetic() {
        let line = |id: &str, model: &str, out: u32| {
            format!(
                r#"{{"type":"assistant","timestamp":"2026-01-02T03:04:05.000Z","sessionId":"s","cwd":"/p","requestId":"r1","costUSD":0.5,"message":{{"id":"{id}","model":"{model}","usage":{{"input_tokens":10.9,"output_tokens":{out},"cache_read_input_tokens":true,"cache_creation_input_tokens":-3,"speed":"fast"}}}}}}"#
            )
        };
        let content = format!(
            "{}\n{}\n{}\nnot json \"usage\"\n{}\n[\"usage\"]\n",
            line("m1", "claude-a", 5),
            line("m1", "claude-a", 99),
            line("m2", "<synthetic>", 1),
            line("m3", "claude-a", 7)
        );
        let recs = parse_claude_records(&tmp_file("claude", &content)).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[0].totals, TokenTotals { uncached: 10, cached: 0, cache_creation: 0, output: 5, reasoning: 0 });
        assert_eq!(recs[0].dedupe_key.as_deref(), Some("m1:r1"));
        assert_eq!(recs[0].reported_cost, Some(0.5));
        assert_eq!(recs[0].speed, Speed::Fast);
        assert_eq!(recs[0].project.as_deref(), Some("/p"));
        assert_eq!(recs[1].totals.output, 7);
    }

    fn tc(ts: &str, last: &str, cum: Option<&str>, window: Option<u64>) -> String {
        let cum = cum.map(|c| format!(r#","total_token_usage":{c}"#)).unwrap_or_default();
        let w = window.map(|w| format!(r#","model_context_window":{w}"#)).unwrap_or_default();
        format!(
            r#"{{"timestamp":"{ts}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{last}{cum}{w}}}}}}}"#
        )
    }

    fn usage(i: u64, c: u64, o: u64) -> String {
        format!(r#"{{"input_tokens":{i},"cached_input_tokens":{c},"output_tokens":{o}}}"#)
    }

    fn header(extra_payload: &str) -> String {
        let meta = format!(
            r#"{{"timestamp":"2026-01-02T03:00:00.000Z","type":"session_meta","payload":{{"id":"sess","cwd":"/w","model_provider":"openai"{extra_payload}}}}}"#
        );
        let turn = r#"{"timestamp":"2026-01-02T03:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5","turn_id":"t1"}}"#;
        format!("{meta}\n{turn}\n")
    }

    #[test]
    fn codex_cumulative_and_duplicates() {
        let mut c = header("");
        c += &(tc("2026-01-02T03:01:00.000Z", &usage(100, 40, 10), Some(&usage(100, 40, 10)), None) + "\n");
        // Duplicate of the same cumulative line is dropped.
        c += &(tc("2026-01-02T03:01:01.000Z", &usage(100, 40, 10), Some(&usage(100, 40, 10)), None) + "\n");
        c += &(tc("2026-01-02T03:02:00.000Z", &usage(50, 0, 5), Some(&usage(150, 40, 15)), None) + "\n");
        // Cumulative that doesn't match last: dropped.
        c += &(tc("2026-01-02T03:03:00.000Z", &usage(10, 0, 1), Some(&usage(999, 40, 16)), None) + "\n");
        let recs = parse_codex_records(&tmp_file("codex-cum", &c)).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!(
            recs[0].totals,
            TokenTotals { uncached: 60, cached: 40, cache_creation: 0, output: 10, reasoning: 0 }
        );
        assert_eq!(recs[1].totals.uncached, 50);
        assert_eq!(recs[0].session_id, "sess");
        assert_eq!(recs[0].project.as_deref(), Some("/w"));
        assert_eq!(recs[0].tier_turn.as_deref(), Some("t1"));
        assert_eq!(recs[0].speed, Speed::Standard);
    }

    #[test]
    fn codex_last_only_dedupes_identical_signature() {
        let mut c = header("");
        c += &(tc("2026-01-02T03:01:00.000Z", &usage(100, 0, 10), None, None) + "\n");
        c += &(tc("2026-01-02T03:01:01.000Z", &usage(100, 0, 10), None, None) + "\n");
        c += &(tc("2026-01-02T03:02:00.000Z", &usage(20, 0, 2), None, None) + "\n");
        let recs = parse_codex_records(&tmp_file("codex-last", &c)).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[1].totals.output, 2);
    }

    #[test]
    fn codex_context_window_reset_line() {
        let mut c = header("");
        c += &(tc("2026-01-02T03:01:00.000Z", &usage(100, 0, 10), Some(&usage(100, 0, 10)), None) + "\n");
        // All-zero last and cumulative whose total equals the context window: a reset, skipped.
        let zero = r#"{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":0}"#;
        c += &(tc("2026-01-02T03:02:00.000Z", zero, Some(zero), Some(0)) + "\n");
        c += &(tc("2026-01-02T03:03:00.000Z", &usage(5, 0, 1), Some(&usage(5, 0, 1)), None) + "\n");
        let recs = parse_codex_records(&tmp_file("codex-reset", &c)).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[1].totals.uncached, 5);
    }

    #[test]
    fn codex_fork_copies_suppressed() {
        let mut c = header(r#","forked_from_id":"parent""#);
        // Copies of the parent's history right after the fork, within 1 s of each other.
        c += &(tc("2026-01-02T03:00:00.500Z", &usage(100, 0, 10), Some(&usage(100, 0, 10)), None) + "\n");
        c += &(tc("2026-01-02T03:00:01.200Z", &usage(50, 0, 5), Some(&usage(150, 0, 15)), None) + "\n");
        // Real new turn after a gap; the cumulative continues from the copied history.
        c += &(tc("2026-01-02T03:05:00.000Z", &usage(30, 0, 3), Some(&usage(180, 0, 18)), None) + "\n");
        let recs = parse_codex_records(&tmp_file("codex-fork", &c)).unwrap();
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].totals.uncached, 30);
    }

    #[test]
    fn codex_tier_resolved_by_thread_settings() {
        let mut c = header("");
        c += "{\"timestamp\":\"2026-01-02T03:00:30.000Z\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_settings\":{\"service_tier\":\"priority\"}}}\n";
        c += &(tc("2026-01-02T03:01:00.000Z", &usage(10, 0, 1), None, None) + "\n");
        let recs = parse_codex_records(&tmp_file("codex-tier", &c)).unwrap();
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].speed, Speed::Fast);
        assert_eq!(recs[0].tier_turn, None);
    }

    #[test]
    fn codex_usage_read_rules() {
        let v = |s: &str| serde_json::from_str::<Value>(s).unwrap();
        assert!(CodexUsage::read(Some(&v(r#"{"input_tokens":1,"output_tokens":1}"#))).is_some());
        assert!(CodexUsage::read(Some(&v(r#"{"input_tokens":1.5,"output_tokens":1}"#))).is_none());
        assert!(
            CodexUsage::read(Some(&v(r#"{"input_tokens":1,"output_tokens":1,"cached_input_tokens":null}"#))).is_none()
        );
        assert!(
            CodexUsage::read(Some(&v(r#"{"input_tokens":1,"output_tokens":1,"cached_input_tokens":2}"#))).is_none()
        );
        assert!(CodexUsage::read(Some(&v(r#"{"input_tokens":1}"#))).is_none());
    }

    #[test]
    fn make_rows_ids() {
        let rates = ModelRates::empty();
        let mk = |provider: &str, session: &str, key: Option<&str>| UsageRecord {
            provider: provider.into(),
            ts_ms: 1000,
            model: "m".into(),
            rate_model: None,
            session_id: session.into(),
            project: None,
            totals: TokenTotals { uncached: 1, cached: 2, cache_creation: 3, output: 4, reasoning: 5 },
            reported_cost: None,
            speed: Speed::Standard,
            dedupe_key: key.map(str::to_string),
            tier_turn: None,
        };
        let recs = vec![
            mk("codex", "s", None),
            mk("codex", "s", None),
            mk("codex", "", None),
            mk("claude", "", Some("k:r")),
            mk("claude", "", None),
        ];
        let rows = make_rows(&recs, "/f", "burn", Some("proj"), &rates);
        assert_eq!(rows[0].id, "codex:s:1000:m:1:2:3:4:5#1");
        assert_eq!(rows[1].id, "codex:s:1000:m:1:2:3:4:5#2");
        assert_eq!(rows[2].id, "codex:/f#2");
        assert_eq!(rows[3].id, "k:r");
        assert_eq!(rows[4].id, "claude:/f#4");
        assert_eq!(rows[0].session.as_deref(), Some("s"));
        assert_eq!(rows[2].session, None);
        assert_eq!(rows[0].project.as_deref(), Some("proj"));
        assert_eq!(rows[0].day.len(), 10);
        assert_eq!(rows[0].ts.len(), 19);
    }

    #[test]
    fn t3_cache_version_names() {
        assert_eq!(t3_cache_version("usage-scan-cache-v7.json"), 7);
        assert_eq!(t3_cache_version("usage-scan-cache.json"), 0);
        assert_eq!(t3_cache_version("usage-scan-cache-vx.json"), 0);
    }

    #[test]
    fn t3_cache_decode() {
        let json = r#"{
          "version": 7, "models": ["claude-a", "<synthetic>", "gpt-5"], "sessions": ["s0"],
          "files": {
            "/b/proj-dir/x.jsonl": {"p":"claude","s":10,"m":5,
              "r":[[1000,0,0,1,2,3,4,0,"k1",0.5,1,null,"turn"],[1001,1,0,1,1,1,1,0,"k2",null,0,null,"t"]],
              "t":[[1002,0,0,9,9,9,9,0,"k1",null,0,null,"t"]]},
            "/a/codex.jsonl": {"p":"codex","s":20,"m":6,
              "r":[[2000,2,0,5,0,0,1,0,null,null,2,0,"tt"]],"t":[]},
            "/c/bad.jsonl": {"p":"claude","s":1,"m":1,"r":[[1,99,0,1,1,1,1,0,null,null,0,null]],"t":[]},
            "/d/other.jsonl": {"p":"cursor","s":1,"m":1,"r":[],"t":[]}
          }}"#;
        let p = tmp_file("t3cache", json);
        let files = parse_t3_cache(&p).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path, "/a/codex.jsonl");
        assert_eq!(files[1].path, "/b/proj-dir/x.jsonl");
        let cl = &files[1];
        assert_eq!(cl.size, 10);
        // Synthetic skipped; k1 in the tail deduped against the first.
        assert_eq!(cl.records.len(), 1);
        assert_eq!(cl.records[0].project.as_deref(), Some("proj-dir"));
        assert_eq!(cl.records[0].speed, Speed::Fast);
        assert_eq!(cl.records[0].reported_cost, Some(0.5));
        assert_eq!(cl.records[0].tier_turn.as_deref(), Some("turn"));
        assert_eq!(cl.records[0].session_id, "s0");
        let cx = &files[0].records[0];
        assert_eq!(cx.rate_model.as_deref(), Some("claude-a"));
        assert_eq!(cx.speed, Speed::Ultrafast);
        assert_eq!(cx.project, None);

        // Versions outside 4...17 decode to nothing; version 6 ignores the tier column.
        let v18 = json.replace("\"version\": 7", "\"version\": 18");
        assert!(parse_t3_cache(&tmp_file("t3cache18", &v18)).unwrap().is_empty());
        let v6 = json.replace("\"version\": 7", "\"version\": 6");
        let f6 = parse_t3_cache(&tmp_file("t3cache6", &v6)).unwrap();
        assert_eq!(f6[1].records[0].tier_turn, None);
    }
}
