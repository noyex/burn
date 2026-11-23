//! Port of `AntigravityUsage.swift` and T3 Code's `antigravityUsageReader.ts`.
//! Reads protobuf token-usage blobs from Antigravity conversation SQLite databases.

use crate::parsers::{Speed, TokenTotals, UsageRecord};
use crate::paths::Paths;
use rusqlite::{Connection, OpenFlags};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

fn model_id_name(id: i64) -> Option<&'static str> {
    Some(match id {
        246 => "gemini-2.5-pro",
        312 => "gemini-2.5-flash",
        313 | 329 => "gemini-2.5-flash-thinking",
        330 => "gemini-2.5-flash-lite",
        281 | 282 => "claude-sonnet-4",
        290 | 291 => "claude-opus-4",
        333 | 334 => "claude-sonnet-4-5",
        340 | 341 => "claude-haiku-4-5",
        342 => "gpt-oss-120b-medium",
        1026 => "claude-opus-4-6",
        1035 => "claude-sonnet-4-6",
        1016 | 1036 | 1037 => "gemini-3.1-pro",
        1018 | 1084 | 1047 => "gemini-3-flash-preview",
        1020 => "gemini-3.5-flash-medium",
        1021 => "gemini-3.1-flash-image",
        1050 => "gemini-3.1-flash-lite",
        1071 => "gemini-3.6-flash-high",
        1072 => "gemini-3.6-flash-medium",
        1073 => "gemini-3.6-flash-low",
        1132 | 1133 => "gemini-3.5-flash-high",
        1187 => "gemini-3.5-flash-extra-low",
        1196 | 1266 => "gemini-3.6-flash",
        1298 => "gemini-3.7-flash-high",
        1299 => "gemini-3.7-flash-medium",
        1300 => "gemini-3.7-flash-low",
        1301 => "gemini-3.7-flash-tiered",
        1318 => "gemini-3.8-flash-high",
        1319 => "gemini-3.8-flash-medium",
        1320 => "gemini-3.8-flash-low",
        1322 => "gemini-3.8-flash-tiered",
        1402 => "claude-opus-5-5",
        1417..=1419 => "gemini-4-argon",
        1537 => "gemini-pro-orchestrator-neon",
        _ => return None,
    })
}

pub fn rate_model(model: &str) -> String {
    if matches!(model, "gemini-3-flash-agent" | "gemini-3-flash-agent-a" | "gemini-3-flash-agent-b" | "gemini-3-flash-a" | "gemini-3-flash-b") {
        return "gemini-3.5-flash".into();
    }
    if model == "gemini-3.7-flash-safety-le" {
        return "gemini-3.7-flash".into();
    }
    if model == "gemini-pro-orchestrator-neon" {
        return "gemini-4-neon".into();
    }
    if model == "gemini-pro-orchestrator-g1-pro" {
        return "gemini-4-argon".into();
    }
    const SUFFIXES: [&str; 9] = [
        "-extra-low",
        "-low",
        "-medium",
        "-high",
        "-tiered",
        "-control",
        "-thinking",
        "-agent",
        "-orchestrator",
    ];
    let mut base = model;
    loop {
        let mut stripped = false;
        for s in SUFFIXES {
            if let Some(rest) = base.strip_suffix(s) {
                base = rest;
                stripped = true;
                break;
            }
        }
        if !stripped {
            break;
        }
    }
    if base == "gemini-3-flash" {
        "gemini-3-flash-preview".into()
    } else {
        base.into()
    }
}

pub fn normalize_model_name(name: &str) -> String {
    if name.is_empty() {
        return String::new();
    }
    let mut s = name.to_lowercase();
    let trimmed = s.trim_end();
    if trimmed.ends_with(')')
        && let Some(open) = trimmed.rfind('(')
    {
        let prefix = trimmed[..open].trim_end();
        let inner = &trimmed[open + 1..trimmed.len() - 1];
        s = format!("{prefix}-{inner}");
    }
    let s = s.split_whitespace().collect::<Vec<_>>().join("-");
    if let Some(rest) = s.strip_prefix("claude-") {
        // claude-4.6-opus -> claude-opus-4-6
        let parts: Vec<&str> = rest.split('-').collect();
        if parts.len() >= 2
            && parts[0].bytes().all(|b| b.is_ascii_digit() || b == b'.')
            && matches!(parts[1], "sonnet" | "opus" | "haiku")
        {
            let mut out = format!("claude-{}-{}", parts[1], parts[0]);
            for p in &parts[2..] {
                out.push('-');
                out.push_str(p);
            }
            return out.replace('.', "-");
        }
        return s.replace('.', "-");
    }
    s
}

pub fn is_concrete_model(model: &str) -> bool {
    if matches!(model, "gemini-3-flash-agent" | "gemini-3-flash-agent-a" | "gemini-3-flash-agent-b" | "gemini-3-flash-a" | "gemini-3-flash-b") {
        return false;
    }
    if let Some(rest) = model.strip_prefix("gemini-") {
        return rest.as_bytes().first().is_some_and(u8::is_ascii_digit);
    }
    for fam in ["claude-sonnet-", "claude-opus-", "claude-haiku-"] {
        if let Some(rest) = model.strip_prefix(fam) {
            return rest.as_bytes().first().is_some_and(u8::is_ascii_digit);
        }
    }
    model.starts_with("gpt-")
}

/// Conversation directories holding Antigravity `.db` files (mirrors `AntigravityUsage.ts`).
pub fn conversation_dirs(paths: &Paths) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(env_val) = std::env::var("ANTIGRAVITY_DATA_DIR") {
        let configured: Vec<&str> = env_val.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
        if !configured.is_empty() {
            for r in configured {
                let p = if let Some(rest) = r.strip_prefix("~/") {
                    paths.home.join(rest)
                } else if r == "~" {
                    paths.home.clone()
                } else {
                    PathBuf::from(r)
                };
                roots.push(p);
            }
        }
    }
    if roots.is_empty() {
        for name in ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup"] {
            roots.push(paths.home.join(".gemini").join(name));
        }
        roots.push(paths.home.join(".config").join("antigravity"));
    }
    let t3_root = paths.t3_userdata().join("providers").join("antigravity");
    if let Ok(entries) = std::fs::read_dir(&t3_root) {
        let mut names: Vec<PathBuf> = entries.flatten().map(|e| e.path().join("antigravity-acp")).collect();
        names.sort();
        roots.extend(names);
    }

    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for root in roots {
        let resolved = std::fs::canonicalize(&root).unwrap_or(root);
        let nested = resolved.join("conversations");
        let dir = if nested.exists() { nested } else { resolved };
        let canonical = std::fs::canonicalize(&dir).unwrap_or(dir);
        if seen.insert(canonical.clone()) {
            out.push(canonical);
        }
    }
    out
}

// MARK: Protobuf wire parser

#[derive(Clone)]
enum Wire<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
}

type Fields<'a> = HashMap<u32, Vec<Wire<'a>>>;

fn parse_fields(data: &[u8]) -> Option<Fields<'_>> {
    let mut out: Fields<'_> = HashMap::new();
    let mut off = 0;
    let varint = |off: &mut usize| -> Option<u64> {
        let mut val: u64 = 0;
        let mut shift = 0u32;
        while shift < 70 {
            let b = *data.get(*off)?;
            *off += 1;
            if shift == 63 && b > 1 {
                return None;
            }
            val |= u64::from(b & 0x7f) << shift;
            if b < 0x80 {
                return Some(val);
            }
            shift += 7;
        }
        None
    };
    while off < data.len() {
        let tag = varint(&mut off)?;
        let num = u32::try_from(tag >> 3).ok()?;
        let wire = tag & 7;
        if num == 0 {
            return None;
        }
        match wire {
            0 => {
                let v = varint(&mut off)?;
                out.entry(num).or_default().push(Wire::Varint(v));
            }
            1 => {
                if data.len() - off < 8 {
                    return None;
                }
                off += 8;
            }
            5 => {
                if data.len() - off < 4 {
                    return None;
                }
                off += 4;
            }
            2 => {
                let len = usize::try_from(varint(&mut off)?).ok()?;
                if data.len() - off < len {
                    return None;
                }
                let slice = &data[off..off + len];
                off += len;
                out.entry(num).or_default().push(Wire::Bytes(slice));
            }
            _ => return None,
        }
    }
    Some(out)
}

fn num_at(f: &Fields<'_>, key: u32) -> i64 {
    match f.get(&key).and_then(|v| v.first()) {
        Some(Wire::Varint(v)) => i64::try_from(*v).unwrap_or(0),
        _ => 0,
    }
}

fn bytes_at<'a>(f: &Fields<'a>, key: u32) -> Option<&'a [u8]> {
    match f.get(&key).and_then(|v| v.first()) {
        Some(Wire::Bytes(b)) => Some(b),
        _ => None,
    }
}

fn nested<'a>(f: &Fields<'a>, key: u32) -> Option<Fields<'a>> {
    match bytes_at(f, key) {
        Some(b) => parse_fields(b),
        None => Some(HashMap::new()),
    }
}

fn text_at(f: &Fields<'_>, key: u32) -> String {
    bytes_at(f, key).and_then(|b| std::str::from_utf8(b).ok()).map(|s| s.trim().to_string()).unwrap_or_default()
}

fn proto_ts_ms(f: &Fields<'_>) -> Option<i64> {
    let secs = num_at(f, 1);
    (secs > 0).then(|| secs * 1000 + num_at(f, 2) / 1_000_000)
}

// MARK: Database decoding

struct RawUsage {
    model_id: i64,
    totals: TokenTotals,
    keys: Vec<String>,
}

struct MetadataEntry {
    model: String,
    model_id: i64,
    timestamp_ms: Option<i64>,
    usages: Vec<RawUsage>,
}

fn decode_usage(u: &Fields<'_>) -> RawUsage {
    let out = num_at(u, 3).max(num_at(u, 9) + num_at(u, 10));
    let totals = TokenTotals {
        uncached: num_at(u, 2),
        cached: num_at(u, 5),
        cache_creation: num_at(u, 4),
        output: out,
        reasoning: out.min(num_at(u, 9)),
    };
    let mut keys = Vec::new();
    for k in [11u32, 12, 7] {
        let id = text_at(u, k);
        if !id.is_empty() {
            keys.push(format!("antigravity:{k}:{id}"));
        }
    }
    RawUsage { model_id: num_at(u, 1), totals, keys }
}

fn decode_metadata(bytes: &[u8], step: bool) -> Option<MetadataEntry> {
    let root = parse_fields(bytes)?;
    if !step && bytes_at(&root, 1).is_none() {
        return None;
    }
    let owned_data;
    let data = if step {
        &root
    } else {
        owned_data = nested(&root, 1)?;
        &owned_data
    };
    let owned_model;
    let model_f = if step {
        owned_model = nested(data, 24)?;
        &owned_model
    } else {
        data
    };
    let primary_usage = match bytes_at(data, if step { 9 } else { 4 }) {
        Some(b) => Some(parse_fields(b)?),
        None => None,
    };
    let mut usages = Vec::new();
    if let Some(pu) = &primary_usage {
        usages.push(decode_usage(pu));
    }
    if let Some(retries) = data.get(&(if step { 28 } else { 17 })) {
        for item in retries {
            let Wire::Bytes(b) = item else { return None };
            let r = parse_fields(b)?;
            if let Some(ru) = bytes_at(&r, 2) {
                usages.push(decode_usage(&parse_fields(ru)?));
            }
        }
    }
    let names = [
        normalize_model_name(&text_at(model_f, if step { 12 } else { 19 })),
        normalize_model_name(&text_at(model_f, if step { 8 } else { 21 })),
    ];
    let chosen = names
        .iter()
        .find(|n| is_concrete_model(n))
        .or_else(|| names.iter().find(|n| !n.is_empty() && !n.starts_with("model_") && !n.starts_with("model-")))
        .cloned()
        .unwrap_or_default();
    let mid = num_at(model_f, if step { 1 } else { 3 });
    let model_id = if mid != 0 { mid } else { primary_usage.as_ref().map_or(0, |pu| num_at(pu, 1)) };
    let timestamp_ms = if step {
        proto_ts_ms(&nested(data, 8)?).or_else(|| proto_ts_ms(&nested(data, 1).unwrap_or_default()))
    } else {
        let n9 = nested(data, 9)?;
        proto_ts_ms(&nested(&n9, 4)?)
    };
    Some(MetadataEntry { model: chosen, model_id, timestamp_ms, usages })
}

struct Candidate {
    record: UsageRecord,
    model_quality: u8,
    keys: Vec<String>,
    ts_quality: u8,
}

struct Group {
    candidate: Candidate,
    parent: usize,
    size: usize,
    owner: usize,
}

fn remember_model(map: &mut HashMap<i64, Option<String>>, id: i64, model: &str) {
    match map.get_mut(&id) {
        Some(Some(prev)) if prev != model => *map.get_mut(&id).unwrap() = None,
        Some(_) => {}
        None => {
            map.insert(id, Some(model.to_string()));
        }
    }
}

fn immutable_uri(path: &Path) -> String {
    let raw = path.to_string_lossy().replace('\\', "/");
    let mut uri = String::from(if raw.starts_with('/') { "file://" } else { "file:///" });
    for c in raw.chars() {
        match c {
            '%' => uri.push_str("%25"),
            '?' => uri.push_str("%3f"),
            '#' => uri.push_str("%23"),
            _ => uri.push(c),
        }
    }
    uri.push_str("?immutable=1");
    uri
}

pub fn parse_database(path: &Path) -> Option<Vec<UsageRecord>> {
    // Closed conversations are WAL databases without `-wal`/`-shm`; a plain read-only open can't
    // create the `-shm` and fails, so open those as immutable. Live ones keep their WAL readable.
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX | OpenFlags::SQLITE_OPEN_URI;
    let mut wal = path.as_os_str().to_owned();
    wal.push("-wal");
    let conn = if Path::new(&wal).exists() {
        Connection::open_with_flags(path, flags).ok()?
    } else {
        Connection::open_with_flags(immutable_uri(path), flags).ok()?
    };
    conn.busy_timeout(Duration::from_millis(100)).ok()?;

    let tables: HashSet<String> = {
        let mut stmt = conn.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").ok()?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).ok()?;
        rows.flatten().collect()
    };
    if !tables.contains("gen_metadata") && !tables.contains("steps") {
        return Some(Vec::new());
    }

    let read_entries = |sql: &str, step: bool| -> Option<Vec<(i64, MetadataEntry)>> {
        let mut stmt = conn.prepare(sql).ok()?;
        let mut rows = stmt.query([]).ok()?;
        let mut out = Vec::new();
        while let Some(r) = rows.next().ok()? {
            let idx: i64 = r.get(0).ok()?;
            let blob: Option<Vec<u8>> = r.get(1).ok()?;
            let Some(blob) = blob else {
                if step {
                    continue;
                }
                return None;
            };
            out.push((idx, decode_metadata(&blob, step)?));
        }
        out.sort_by_key(|(idx, _)| *idx);
        Some(out)
    };

    let generations = if tables.contains("gen_metadata") {
        read_entries("SELECT idx, data FROM gen_metadata ORDER BY rowid", false)?
    } else {
        Vec::new()
    };
    let mut trajectory_ts = None;
    if tables.contains("trajectory_metadata_blob")
        && let Ok(mut stmt) = conn.prepare("SELECT data FROM trajectory_metadata_blob")
        && let Ok(mut rows) = stmt.query([])
    {
        while let Ok(Some(r)) = rows.next() {
            if trajectory_ts.is_some() {
                break;
            }
            if let Ok(blob) = r.get::<_, Vec<u8>>(0)
                && let Some(root) = parse_fields(&blob)
                && let Some(n2) = nested(&root, 2)
            {
                trajectory_ts = proto_ts_ms(&n2);
            }
        }
    }
    let steps = if tables.contains("steps") {
        read_entries("SELECT idx, metadata FROM steps ORDER BY rowid", true)?
    } else {
        Vec::new()
    };

    let fallback_ms = std::fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as i64);
    let session_id = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();

    let mut learned: HashMap<i64, Option<String>> = HashMap::new();
    for (_, e) in generations.iter().chain(steps.iter()) {
        if e.model_id > 0 && is_concrete_model(&e.model) {
            remember_model(&mut learned, e.model_id, &e.model);
        }
    }
    let gen_by_idx: HashMap<i64, &MetadataEntry> = generations.iter().map(|(i, e)| (*i, e)).collect();

    let mut candidates = Vec::new();
    for (source, entries) in [("step", &steps), ("generation", &generations)] {
        for (index, (idx, entry)) in entries.iter().enumerate() {
            for (u_idx, usage) in entry.usages.iter().enumerate() {
                if usage.totals.total() == 0 {
                    continue;
                }
                let model_id = if usage.model_id != 0 { usage.model_id } else { entry.model_id };
                let generation = if source == "step" { gen_by_idx.get(idx).copied() } else { None };
                let matches = |m: &MetadataEntry| model_id == 0 || m.model_id == model_id;
                let mut model = if matches(entry) && !entry.model.is_empty() {
                    entry.model.clone()
                } else if let Some(g) = generation
                    && matches(g)
                    && !g.model.is_empty()
                {
                    g.model.clone()
                } else {
                    String::new()
                };

                let base_q: u8 = if is_concrete_model(&model) {
                    4
                } else if !model.is_empty() {
                    1
                } else {
                    0
                };
                let learned_opt = learned.get(&model_id);
                let learned_name = learned_opt.and_then(|o| o.as_deref());
                let fallback = if matches!(learned_opt, Some(None)) { None } else { model_id_name(model_id) };
                if base_q < 4 {
                    if let Some(l) = learned_name {
                        model = l.to_string();
                    } else if let Some(fb) = fallback {
                        model = fb.to_string();
                    } else if model.is_empty() {
                        model = if model_id > 0 {
                            format!("antigravity-model-{model_id}")
                        } else {
                            "antigravity-unknown".to_string()
                        };
                    }
                }
                let final_q = if base_q == 4 {
                    4
                } else if learned_name.is_some() {
                    3
                } else if fallback.is_some() {
                    2
                } else {
                    base_q
                };

                let ts_ms = entry.timestamp_ms.or(trajectory_ts).unwrap_or(fallback_ms);
                let ts_quality = if entry.timestamp_ms.is_some() {
                    2
                } else if trajectory_ts.is_some() {
                    1
                } else {
                    0
                };
                let dedupe_key = usage
                    .keys
                    .first()
                    .cloned()
                    .unwrap_or_else(|| format!("antigravity:{session_id}:{source}:{index}:{u_idx}"));

                candidates.push(Candidate {
                    record: UsageRecord {
                        provider: "antigravity".into(),
                        ts_ms,
                        model,
                        rate_model: None,
                        session_id: session_id.clone(),
                        project: None,
                        totals: usage.totals,
                        reported_cost: None,
                        speed: Speed::Standard,
                        dedupe_key: Some(dedupe_key),
                        tier_turn: None,
                    },
                    model_quality: final_q,
                    keys: usage.keys.clone(),
                    ts_quality,
                });
            }
        }
    }

    // Union-Find deduplication across steps, generations, and retries.
    let mut groups: Vec<Group> = Vec::with_capacity(candidates.len());
    let mut identities: HashMap<String, usize> = HashMap::new();

    fn find(groups: &mut [Group], mut idx: usize) -> usize {
        let mut root = idx;
        while groups[root].parent != root {
            root = groups[root].parent;
        }
        while idx != root {
            let p = groups[idx].parent;
            groups[idx].parent = root;
            idx = p;
        }
        root
    }

    fn merge(groups: &mut [Group], left: usize, right: usize) {
        let mut a = find(groups, left);
        let mut b = find(groups, right);
        if a == b {
            return;
        }
        if groups[a].size < groups[b].size {
            std::mem::swap(&mut a, &mut b);
        }
        let target_owner = groups[a].owner;
        let source_owner = groups[b].owner;
        let first_is_source = source_owner < target_owner;
        let best_model_is_source = if groups[b].candidate.model_quality == groups[a].candidate.model_quality {
            first_is_source
        } else {
            groups[b].candidate.model_quality > groups[a].candidate.model_quality
        };
        let best_time_is_source = groups[b].candidate.ts_quality > groups[a].candidate.ts_quality
            || (groups[b].candidate.ts_quality == groups[a].candidate.ts_quality
                && groups[b].candidate.record.ts_ms < groups[a].candidate.record.ts_ms);

        let x = groups[a].candidate.record.totals;
        let y = groups[b].candidate.record.totals;
        let totals = TokenTotals {
            uncached: x.uncached.max(y.uncached),
            cached: x.cached.max(y.cached),
            cache_creation: x.cache_creation.max(y.cache_creation),
            output: x.output.max(y.output),
            reasoning: x.reasoning.max(y.reasoning),
        };
        let model = if best_model_is_source {
            groups[b].candidate.record.model.clone()
        } else {
            groups[a].candidate.record.model.clone()
        };
        let model_quality = groups[a].candidate.model_quality.max(groups[b].candidate.model_quality);
        let (ts_ms, ts_quality) = if best_time_is_source {
            (groups[b].candidate.record.ts_ms, groups[b].candidate.ts_quality)
        } else {
            (groups[a].candidate.record.ts_ms, groups[a].candidate.ts_quality)
        };
        if first_is_source {
            groups[a].candidate.record = groups[b].candidate.record.clone();
            groups[a].owner = source_owner;
        }
        groups[a].candidate.record.model = model;
        groups[a].candidate.record.ts_ms = ts_ms;
        groups[a].candidate.record.totals = totals;
        groups[a].candidate.model_quality = model_quality;
        groups[a].candidate.ts_quality = ts_quality;
        groups[a].size += groups[b].size;
        groups[b].parent = a;
    }

    for candidate in candidates {
        let index = groups.len();
        let keys = candidate.keys.clone();
        groups.push(Group { candidate, parent: index, size: 1, owner: index });
        for key in keys {
            if let Some(&existing) = identities.get(&key) {
                merge(&mut groups, index, existing);
            }
            identities.insert(key, index);
        }
    }

    let mut out = Vec::new();
    for (index, mut g) in groups.into_iter().enumerate() {
        if g.parent != index {
            continue;
        }
        let rm = rate_model(&g.candidate.record.model);
        if rm != g.candidate.record.model {
            g.candidate.record.rate_model = Some(rm);
        }
        out.push(g.candidate.record);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_model_mappings() {
        assert_eq!(rate_model("gemini-4-neon-high"), "gemini-4-neon");
        assert_eq!(rate_model("gemini-4-hydrogen-tiered-high"), "gemini-4-hydrogen");
        assert_eq!(rate_model("gemini-pro-orchestrator-neon"), "gemini-4-neon");
        assert_eq!(rate_model("gemini-pro-orchestrator-g1-pro"), "gemini-4-argon");
        assert_eq!(rate_model("gemini-3-flash-agent"), "gemini-3.5-flash");
        assert_eq!(rate_model("gemini-3-flash-high"), "gemini-3-flash-preview");
    }

    #[test]
    fn model_name_normalization() {
        assert_eq!(normalize_model_name("Gemini 4 Neon (High)"), "gemini-4-neon-high");
        assert_eq!(normalize_model_name("Claude 4.6 Opus"), "claude-opus-4-6");
        assert!(is_concrete_model("gemini-4-neon"));
        assert!(!is_concrete_model("gemini-3-flash-agent"));
    }
}
