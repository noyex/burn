//! Port of `ModelRates.swift`: the LiteLLM price table, T3's overrides and aliases, pricing.

use crate::parsers::Speed;
use crate::paths::Paths;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

/// Per-token prices of one speed tier.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TokenRates {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_creation: f64,
}

impl TokenRates {
    pub fn scaled(&self, m: f64) -> TokenRates {
        TokenRates {
            input: self.input * m,
            output: self.output * m,
            cache_read: self.cache_read * m,
            cache_creation: self.cache_creation * m,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ModelRate {
    pub standard: TokenRates,
    pub fast: Option<TokenRates>,
    pub ultrafast: Option<TokenRates>,
}

impl ModelRate {
    pub fn rates(&self, speed: Speed) -> TokenRates {
        match speed {
            Speed::Standard => self.standard,
            Speed::Fast => self.fast.unwrap_or(self.standard),
            Speed::Ultrafast => self.ultrafast.unwrap_or(self.standard),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct ModelRates {
    pub table: Arc<HashMap<String, ModelRate>>,
    pub overrides: HashMap<String, TokenRates>,
    pub aliases: HashMap<String, String>,
    /// Identifies the table, overrides and aliases; a change means stored costs are stale.
    pub hash: String,
}

pub const SOURCE_URL: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";
/// T3's own rates file is trusted for this long, then Burn looks for fresher rates.
const T3_MAX_AGE_SECS: f64 = 3.0 * 24.0 * 3600.0;
const CACHE_MAX_AGE_SECS: f64 = 24.0 * 3600.0;

/// Anthropic list prices for models LiteLLM doesn't list yet; the table wins once it has them.
/// Bump `BUILTIN_VERSION` on every change so stored costs get recomputed.
pub const BUILTIN_VERSION: &str = "2";

static BUILTIN: LazyLock<HashMap<String, ModelRate>> = LazyLock::new(|| {
    let rate = |input: f64, output: f64, cache_read: f64, fast: Option<f64>| {
        // Cache writes (5 min) cost 1.25x input.
        let std = TokenRates {
            input: input / 1e6,
            output: output / 1e6,
            cache_read: cache_read / 1e6,
            cache_creation: input * 1.25 / 1e6,
        };
        ModelRate { standard: std, fast: fast.map(|m| std.scaled(m)), ultrafast: None }
    };
    let fable52 = rate(8.0, 40.0, 0.2, Some(2.0));
    HashMap::from([("claude-fable-5-2".to_string(), fable52), ("claude-mythos-5-2".to_string(), fable52)])
});

const UNPRICEABLE: [&str; 6] = ["<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable"];

impl ModelRates {
    pub fn empty() -> ModelRates {
        ModelRates { hash: "empty".into(), ..Default::default() }
    }

    /// `priceUsage(...).costUsd`: a provider-reported cost wins; otherwise list price at the record's speed.
    #[allow(clippy::too_many_arguments)]
    pub fn cost(
        &self,
        model: &str,
        rate_model: Option<&str>,
        speed: Speed,
        uncached: i64,
        cached: i64,
        cache_creation: i64,
        output: i64,
        reported: Option<f64>,
    ) -> f64 {
        let mut model = model;
        let mut rate_model = rate_model;
        if let Some(target) = self.aliases.get(model) {
            model = target;
            rate_model = None;
        }
        let over = self.overrides.get(model.trim());
        let reported = if over.is_none() { reported.filter(|r| r.is_finite()) } else { None };
        let base = match over {
            Some(o) => Some(ModelRate { standard: *o, fast: None, ultrafast: None }),
            None => self.resolve(rate_model.unwrap_or(model)),
        };
        let Some(base) = base else { return reported.unwrap_or(0.0) };
        let r = base.rates(speed);
        // Same summation order as T3: input + cacheRead + cacheWrite + output.
        let list = uncached as f64 * r.input
            + cached as f64 * r.cache_read
            + cache_creation as f64 * r.cache_creation
            + output as f64 * r.output;
        reported.unwrap_or(list)
    }

    /// `resolveRate`: lowercase, drop a `[1m]`-style suffix, refuse bare family names.
    pub fn resolve(&self, model: &str) -> Option<ModelRate> {
        let key = strip_variant_suffix(&normalize_key(model));
        let bare = bare_name(&key);
        if bare.is_empty() || UNPRICEABLE.contains(&bare) {
            return None;
        }
        self.table.get(key.as_str()).or_else(|| BUILTIN.get(key.as_str())).or_else(|| BUILTIN.get(bare)).copied()
    }

    /// T3's rates copy, then fresh Burn cache, then network, then any stale copy, then nothing. Blocking.
    pub fn load(paths: &Paths) -> ModelRates {
        let t3_path = t3_path(paths);
        let mut t3: Option<(ModelRates, f64)> = None;
        if let Some(e) = read_entry(&t3_path, true).filter(|e| !e.table.is_empty()) {
            t3 = Some((make(&e, paths), now_secs() - e.fetched_at_ms / 1000.0));
        }
        if let Some((r, age)) = &t3
            && *age < T3_MAX_AGE_SECS
        {
            return r.clone();
        }

        let cache = paths.rates_cache();
        let age = std::fs::metadata(&cache)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| SystemTime::now().duration_since(m).ok());
        if let Some(age) = age
            && age.as_secs_f64() < CACHE_MAX_AGE_SECS
            && let Some(r) = read_cache(&cache, paths)
        {
            return r;
        }
        if let Some(data) = fetch()
            && let Some(e) = parse_entry(&data, false)
        {
            let r = make(&e, paths);
            if r.table.len() > 100 {
                let _ = std::fs::create_dir_all(&paths.data_dir);
                let _ = write_atomic(&cache, &data);
                return r;
            }
        }
        read_cache(&cache, paths).or(t3.map(|(r, _)| r)).unwrap_or_else(ModelRates::empty)
    }

    /// Rates exactly as T3 has them on disk, regardless of age (verification).
    pub fn load_t3_only(paths: &Paths) -> Option<ModelRates> {
        let e = read_entry(&t3_path(paths), true).filter(|e| !e.table.is_empty())?;
        Some(make(&e, paths))
    }

    /// A bare LiteLLM document plus the settings found under `paths` (tests and fixtures).
    pub fn from_document(doc: &Value, paths: &Paths) -> ModelRates {
        let digest = Sha256::digest(serde_json::to_vec(doc).unwrap_or_default()).to_vec();
        let table = Arc::new(match doc {
            Value::Object(m) => parse_table(m),
            _ => HashMap::new(),
        });
        make(&FileEntry { table, digest, fetched_at_ms: 0.0 }, paths)
    }
}

pub fn normalize_key(model: &str) -> String {
    model.trim().to_lowercase()
}

pub fn bare_name(key: &str) -> &str {
    match key.rfind('/') {
        Some(i) => &key[i + 1..],
        None => key,
    }
}

pub fn strip_variant_suffix(key: &str) -> String {
    match key.find('[') {
        Some(i) => key[..i].to_string(),
        None => key.to_string(),
    }
}

// MARK: Parsing

/// JSON number (not a boolean), finite.
fn finite(v: Option<&Value>) -> Option<f64> {
    match v {
        Some(Value::Number(n)) => n.as_f64().filter(|d| d.is_finite()),
        _ => None,
    }
}

/// `readTokenRates`: both input and output are required; missing cache rates scale from the standard tier,
/// or fall back to the plain input rate.
fn read_token_rates(e: &Map<String, Value>, suffix: &str, standard: Option<&TokenRates>) -> Option<TokenRates> {
    let input = finite(e.get(&format!("input_cost_per_token{suffix}")))?;
    let output = finite(e.get(&format!("output_cost_per_token{suffix}")))?;
    let cache = |name: &str, std: fn(&TokenRates) -> f64| -> f64 {
        if let Some(v) = finite(e.get(&format!("{name}{suffix}"))) {
            return v;
        }
        match standard {
            Some(s) if s.input > 0.0 => std(s) / s.input * input,
            _ => input,
        }
    };
    Some(TokenRates {
        input,
        output,
        cache_read: cache("cache_read_input_token_cost", |s| s.cache_read),
        cache_creation: cache("cache_creation_input_token_cost", |s| s.cache_creation),
    })
}

const FIRST_PARTY_PROVIDERS: [&str; 7] = ["anthropic", "deepseek", "gemini", "meta", "mistral", "openai", "xai"];

/// `parseRateTable` (LiteLLM document -> normalized-name table, plus bare-name aliases preferring first-party).
pub fn parse_table(document: &Map<String, Value>) -> HashMap<String, ModelRate> {
    let mut table: HashMap<String, ModelRate> = HashMap::with_capacity(document.len());
    // Sorted so that colliding normalized names resolve the same way on every run.
    let mut names: Vec<&String> = document.keys().collect();
    names.sort();
    for name in names {
        let Value::Object(e) = &document[name] else { continue };
        let Some(standard) = read_token_rates(e, "", None) else { continue };
        let key = normalize_key(name);
        if key.is_empty() {
            continue;
        }
        let multiple = match e.get("provider_specific_entry") {
            Some(Value::Object(s)) => finite(s.get("fast")).filter(|f| *f > 0.0),
            _ => None,
        };
        let fast = match multiple {
            Some(m) => Some(standard.scaled(m)),
            None => read_token_rates(e, "_priority", Some(&standard)),
        };
        let ultrafast = read_token_rates(e, "_ultrafast", Some(&standard));
        table.insert(key, ModelRate { standard, fast, ultrafast });
    }
    // (None, _) = ambiguous within the same tier.
    let mut candidates: HashMap<String, (Option<ModelRate>, bool)> = HashMap::new();
    for (key, rate) in &table {
        let alias = bare_name(key);
        if alias.is_empty() || alias == key || table.contains_key(alias) {
            continue;
        }
        let first_party = key.find('/').is_some_and(|i| FIRST_PARTY_PROVIDERS.contains(&&key[..i]));
        match candidates.get_mut(alias) {
            Some((held, held_fp)) => {
                if first_party && !*held_fp {
                    *held = Some(*rate);
                    *held_fp = true;
                } else if first_party == *held_fp
                    && let Some(h) = held
                    && h != rate
                {
                    *held = None;
                }
            }
            None => {
                candidates.insert(alias.to_string(), (Some(*rate), first_party));
            }
        }
    }
    for (alias, (rate, _)) in candidates {
        if let Some(rate) = rate {
            table.insert(alias, rate);
        }
    }
    table
}

struct Settings {
    overrides: HashMap<String, TokenRates>,
    aliases: HashMap<String, String>,
    /// Canonical bytes of the raw settings, for the hash.
    raw: Vec<u8>,
}

/// T3 settings: `usagePriceOverrides` (per million tokens) and `usageModelAliases`.
fn read_settings(paths: &Paths) -> Settings {
    let none = Settings { overrides: HashMap::new(), aliases: HashMap::new(), raw: Vec::new() };
    let Ok(data) = std::fs::read(paths.t3_userdata().join("settings.json")) else { return none };
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(&data) else { return none };
    let mut overrides = HashMap::new();
    if let Some(Value::Object(m)) = root.get("usagePriceOverrides") {
        for (model, v) in m {
            let Value::Object(p) = v else { continue };
            let (Some(i), Some(o)) =
                (finite(p.get("inputCostPerMillionTokens")), finite(p.get("outputCostPerMillionTokens")))
            else {
                continue;
            };
            overrides.insert(
                model.trim().to_string(),
                TokenRates {
                    input: i / 1e6,
                    output: o / 1e6,
                    cache_read: finite(p.get("cacheReadCostPerMillionTokens")).unwrap_or(i) / 1e6,
                    cache_creation: finite(p.get("cacheWriteCostPerMillionTokens")).unwrap_or(i) / 1e6,
                },
            );
        }
    }
    // `resolveModelAliases`: follow chains, drop cycles. Like Swift's `as? [String: String]`, one non-string value voids all.
    let mut raw: HashMap<String, String> = HashMap::new();
    if let Some(Value::Object(m)) = root.get("usageModelAliases") {
        let all: Option<Vec<(String, String)>> =
            m.iter().map(|(k, v)| if let Value::String(s) = v { Some((k.clone(), s.clone())) } else { None }).collect();
        if let Some(all) = all {
            raw = all.into_iter().collect();
        }
    }
    let mut aliases = HashMap::new();
    for model in raw.keys() {
        let mut seen: HashSet<&str> = HashSet::from([model.as_str()]);
        let mut target = raw[model].as_str();
        while let Some(next) = raw.get(target) {
            if seen.contains(target) {
                break;
            }
            seen.insert(target);
            target = next;
        }
        if !raw.contains_key(target) {
            aliases.insert(model.clone(), target.to_string());
        }
    }
    let mut canon = Map::new();
    canon.insert("a".into(), serde_json::to_value(&raw).unwrap_or(Value::Null));
    canon.insert("o".into(), root.get("usagePriceOverrides").cloned().unwrap_or_else(|| Value::Object(Map::new())));
    let raw_bytes = serde_json::to_vec(&Value::Object(canon)).unwrap_or_default();
    Settings { overrides, aliases, raw: raw_bytes }
}

/// A parsed rates file: the table plus a digest of the raw bytes (cheap, unlike re-serializing the document).
struct FileEntry {
    table: Arc<HashMap<String, ModelRate>>,
    digest: Vec<u8>,
    fetched_at_ms: f64,
}

type EntryCache = HashMap<String, (String, Arc<FileEntry>)>;

/// Parsed files, keyed by path and invalidated by (size, mtime), so repeated syncs don't re-parse a 2 MB JSON.
static FILE_CACHE: LazyLock<Mutex<EntryCache>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// `wrapped`: T3's file keeps the LiteLLM document under `document`; Burn's own cache is the bare document.
fn parse_entry(data: &[u8], wrapped: bool) -> Option<FileEntry> {
    let Value::Object(root) = serde_json::from_slice::<Value>(data).ok()? else { return None };
    let fetched_at_ms = match root.get("fetchedAtMs") {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        _ => 0.0,
    };
    let table = if wrapped {
        match root.get("document") {
            Some(Value::Object(doc)) => parse_table(doc),
            _ => return None,
        }
    } else {
        parse_table(&root)
    };
    Some(FileEntry { table: Arc::new(table), digest: Sha256::digest(data).to_vec(), fetched_at_ms })
}

fn read_entry(path: &Path, wrapped: bool) -> Option<Arc<FileEntry>> {
    let meta = std::fs::metadata(path).ok()?;
    let mtime = meta.modified().ok().and_then(|m| m.duration_since(UNIX_EPOCH).ok()).unwrap_or_default();
    let stamp = format!("{}|{}.{}", meta.len(), mtime.as_secs(), mtime.subsec_nanos());
    let key = path.to_string_lossy().into_owned();
    if let Some((s, e)) = FILE_CACHE.lock().ok()?.get(&key)
        && *s == stamp
    {
        return Some(e.clone());
    }
    let data = std::fs::read(path).ok()?;
    let e = Arc::new(parse_entry(&data, wrapped)?);
    FILE_CACHE.lock().ok()?.insert(key, (stamp, e.clone()));
    Some(e)
}

/// The hash covers the raw rates bytes plus T3's overrides / aliases.
fn make(entry: &FileEntry, paths: &Paths) -> ModelRates {
    let s = read_settings(paths);
    let mut h = Sha256::new();
    h.update(&entry.digest);
    h.update(&s.raw);
    h.update(BUILTIN_VERSION.as_bytes());
    let hash = crate::util::hex(&h.finalize());
    ModelRates { table: entry.table.clone(), overrides: s.overrides, aliases: s.aliases, hash }
}

// MARK: Loading

fn t3_path(paths: &Paths) -> std::path::PathBuf {
    paths.t3_userdata().join("usage-model-rates.json")
}

fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn read_cache(path: &Path, paths: &Paths) -> Option<ModelRates> {
    let e = read_entry(path, false).filter(|e| !e.table.is_empty())?;
    Some(make(&e, paths))
}

/// Last failed download; offline, every import would otherwise wait up to 15 s for it again.
static LAST_FAILED_FETCH: Mutex<Option<SystemTime>> = Mutex::new(None);
const FETCH_RETRY_SECS: u64 = 3600;

fn fetch() -> Option<Vec<u8>> {
    let mut failed = LAST_FAILED_FETCH.lock().ok()?;
    if failed.is_some_and(|t| t.elapsed().is_ok_and(|e| e.as_secs() < FETCH_RETRY_SECS)) {
        return None;
    }
    match crate::limits::http::get_limited(SOURCE_URL, &[], 64 * 1024 * 1024) {
        Ok((200, body)) => {
            *failed = None;
            Some(body)
        }
        _ => {
            *failed = Some(SystemTime::now());
            None
        }
    }
}

fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tmp_paths(tag: &str) -> Paths {
        let dir = std::env::temp_dir().join(format!("burn-rates-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".t3").join("userdata")).unwrap();
        Paths::with_home(dir.clone(), dir.join("data"))
    }

    fn write_settings(p: &Paths, v: Value) {
        std::fs::write(p.t3_userdata().join("settings.json"), serde_json::to_vec(&v).unwrap()).unwrap();
    }

    fn doc() -> Value {
        json!({
            "gpt-x": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "cache_read_input_token_cost": 1e-7,
                      "input_cost_per_token_priority": 2e-6, "output_cost_per_token_priority": 4e-6},
            "claude-y": {"input_cost_per_token": 3e-6, "output_cost_per_token": 15e-6, "provider_specific_entry": {"fast": 2}},
            "vendor/shared": {"input_cost_per_token": 1e-6, "output_cost_per_token": 1e-6},
            "other/shared": {"input_cost_per_token": 2e-6, "output_cost_per_token": 2e-6},
            "a/same": {"input_cost_per_token": 1e-6, "output_cost_per_token": 1e-6},
            "b/same": {"input_cost_per_token": 1e-6, "output_cost_per_token": 1e-6},
            "broken": {"input_cost_per_token": 1e-6},
            "spec": {"sample_spec": true}
        })
    }

    #[test]
    fn list_price_and_tiers() {
        let p = tmp_paths("tiers");
        let r = ModelRates::from_document(&doc(), &p);
        let std = r.cost("gpt-x", None, Speed::Standard, 1000, 1000, 0, 1000, None);
        assert!((std - (1000.0 * 1e-6 + 1000.0 * 1e-7 + 1000.0 * 2e-6)).abs() < 1e-12);
        // Priority tier: cache read scales from standard (1e-7 / 1e-6 * 2e-6).
        let fast = r.cost("gpt-x", None, Speed::Fast, 1000, 1000, 0, 1000, None);
        assert!((fast - (1000.0 * 2e-6 + 1000.0 * 2e-7 + 1000.0 * 4e-6)).abs() < 1e-12);
        // Fast multiple.
        let c = r.cost("claude-y", None, Speed::Fast, 1000, 0, 0, 0, None);
        assert!((c - 1000.0 * 6e-6).abs() < 1e-12);
        // No ultrafast tier: standard.
        assert_eq!(
            r.cost("gpt-x", None, Speed::Ultrafast, 1, 0, 0, 0, None),
            r.cost("gpt-x", None, Speed::Standard, 1, 0, 0, 0, None)
        );
        assert!(!r.table.contains_key("broken"));
    }

    #[test]
    fn suffix_case_and_unpriceable() {
        let p = tmp_paths("suffix");
        let r = ModelRates::from_document(&doc(), &p);
        let a = r.cost("GPT-X[1m]", None, Speed::Standard, 1000, 0, 0, 0, None);
        assert!(a > 0.0);
        assert!(r.resolve("opus").is_none());
        assert!(r.resolve("anthropic/Sonnet").is_none());
        assert!(r.resolve("unknown-model").is_none());
        assert_eq!(r.cost("unknown-model", None, Speed::Standard, 1000, 0, 0, 0, Some(0.5)), 0.5);
        assert_eq!(r.cost("unknown-model", None, Speed::Standard, 1000, 0, 0, 0, None), 0.0);
    }

    #[test]
    fn reported_cost_wins_and_rate_model() {
        let p = tmp_paths("reported");
        let r = ModelRates::from_document(&doc(), &p);
        assert_eq!(r.cost("gpt-x", None, Speed::Standard, 1000, 0, 0, 0, Some(0.25)), 0.25);
        assert_eq!(r.cost("gpt-x", None, Speed::Standard, 0, 0, 0, 0, Some(0.25)), 0.25);
        let via = r.cost("whatever", Some("gpt-x"), Speed::Standard, 1000, 0, 0, 0, None);
        assert!((via - 1e-3).abs() < 1e-12);
    }

    #[test]
    fn bare_name_aliases() {
        let p = tmp_paths("bare");
        let r = ModelRates::from_document(&doc(), &p);
        assert!(r.table.contains_key("same"), "identical rates are unambiguous");
        assert!(!r.table.contains_key("shared"), "differing rates are ambiguous");
    }

    #[test]
    fn builtin_fallback_and_table_wins() {
        let p = tmp_paths("builtin");
        let r = ModelRates::from_document(&json!({}), &p);
        let c = r.cost("claude-fable-5-2", None, Speed::Standard, 1_000_000, 0, 0, 0, None);
        assert!((c - 8.0).abs() < 1e-9);
        let f = r.cost("anthropic/claude-fable-5-2[1m]", None, Speed::Fast, 1_000_000, 0, 0, 0, None);
        assert!((f - 16.0).abs() < 1e-9);
        let t = ModelRates::from_document(
            &json!({"claude-fable-5-2": {"input_cost_per_token": 1e-6, "output_cost_per_token": 1e-6}}),
            &p,
        );
        assert!((t.cost("claude-fable-5-2", None, Speed::Standard, 1_000_000, 0, 0, 0, None) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn overrides_and_aliases() {
        let p = tmp_paths("settings");
        write_settings(
            &p,
            json!({
                "usagePriceOverrides": {" my-model ": {"inputCostPerMillionTokens": 10, "outputCostPerMillionTokens": 20}},
                "usageModelAliases": {"a": "b", "b": "gpt-x", "c": "d", "d": "c", "e": "my-model"}
            }),
        );
        let r = ModelRates::from_document(&doc(), &p);
        assert_eq!(r.aliases.get("a").map(String::as_str), Some("gpt-x"));
        assert_eq!(r.aliases.get("b").map(String::as_str), Some("gpt-x"));
        assert!(!r.aliases.contains_key("c") && !r.aliases.contains_key("d"));
        // Override ignores the reported cost and uses per-million prices (cache defaults to input).
        let c = r.cost("my-model", None, Speed::Standard, 1_000_000, 1_000_000, 0, 1_000_000, Some(99.0));
        assert!((c - 40.0).abs() < 1e-9);
        // Alias to an overridden model.
        let e = r.cost("e", None, Speed::Standard, 1_000_000, 0, 0, 0, None);
        assert!((e - 10.0).abs() < 1e-9);
        // Alias drops the rate model.
        let a = r.cost("a", Some("claude-y"), Speed::Standard, 1000, 0, 0, 0, None);
        assert!((a - 1e-3).abs() < 1e-12);
    }

    #[test]
    fn hash_changes_with_settings() {
        let p = tmp_paths("hash");
        let h1 = ModelRates::from_document(&doc(), &p).hash;
        assert_eq!(h1, ModelRates::from_document(&doc(), &p).hash);
        write_settings(&p, json!({"usageModelAliases": {"a": "b"}}));
        assert_ne!(h1, ModelRates::from_document(&doc(), &p).hash);
    }

    #[test]
    fn load_prefers_fresh_t3_file() {
        let p = tmp_paths("load");
        let now_ms = now_secs() * 1000.0;
        let wrapped = json!({"fetchedAtMs": now_ms, "document": doc()});
        std::fs::write(p.t3_userdata().join("usage-model-rates.json"), serde_json::to_vec(&wrapped).unwrap()).unwrap();
        let r = ModelRates::load(&p);
        assert!(r.table.contains_key("gpt-x"));
        assert!(ModelRates::load_t3_only(&p).is_some());
        assert!(ModelRates::load_t3_only(&tmp_paths("load-none")).is_none());
    }
}
