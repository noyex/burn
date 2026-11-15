//! Verification CLI for the data layer. Output mirrors the Mac app's `Burn --dump` / `--import`,
//! so the two can be compared line by line. Never prints tokens.
//!
//!   burn-cli dump        live limits, then per-period summaries from the store
//!   burn-cli import      import logs into the store, then summaries
//!   burn-cli verify-t3   compare parsing and pricing with T3 Code's scan cache
//!   burn-cli json        limits and summaries as JSON (what the UI receives)
//!   burn-cli check-theme <name or path>   what is wrong with a theme (exit 0 when nothing)

use burn_core::database::UsageDatabase;
use burn_core::importer::{self, ImportProgress};
use burn_core::parsers::{self, UsageRecord};
use burn_core::rates::ModelRates;
use burn_core::theme;
use burn_core::{Paths, Period, ProviderId, limits};
use chrono::{Local, TimeZone, Utc};
use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::Instant;

fn main() {
    let paths = Paths::detect();
    match std::env::args().nth(1).as_deref() {
        Some("dump") => {
            dump_limits(&paths);
            print_summaries(&paths);
        }
        Some("import") => import(&paths),
        Some("verify-t3") => verify_t3(&paths),
        Some("json") => json(&paths),
        Some("check-theme") => check_theme(&paths, std::env::args().nth(2).as_deref()),
        _ => {
            eprintln!("usage: burn-cli dump | import | verify-t3 | json | check-theme <name or path>");
            std::process::exit(2);
        }
    }
}

/// The same check `burn.exe --check-theme` runs.
fn check_theme(paths: &Paths, argument: Option<&str>) -> ! {
    let dirs = theme::ThemeDirs { user: paths.themes_dir(), built_in: theme::built_in_dir() };
    let (code, text) = dirs.check(argument, &theme::font_installed);
    println!("{text}");
    std::process::exit(code);
}

fn dump_limits(paths: &Paths) {
    for p in ProviderId::ALL {
        println!("== {} connected={}", p.name(), limits::is_connected(p, paths));
        match limits::fetch(p, paths) {
            Ok(l) => {
                println!("  plan: {}", l.plan.as_deref().unwrap_or("?"));
                for w in &l.windows {
                    let reset = w
                        .resets_at
                        .and_then(|ms| Local.timestamp_millis_opt(ms).single())
                        .map(|d| d.format("%b %-d, %Y at %H:%M").to_string())
                        .unwrap_or_else(|| "-".into());
                    println!("  {} [{}] {:.1}% resets {}", w.id, w.label, w.percent, reset);
                }
            }
            Err(e) => println!("  error: {e} ({e:?})"),
        }
    }
}

fn import(paths: &Paths) {
    let last = Mutex::new(-1i64);
    let t0 = Instant::now();
    let tick = |p: ImportProgress| {
        if p.total == 0 {
            return;
        }
        let decile = (p.done * 10 / p.total) as i64;
        let mut last = last.lock().unwrap();
        if decile != *last {
            *last = decile;
            println!("  progress {}% ({}/{})", decile * 10, p.done, p.total);
        }
    };
    match importer::run(paths, &tick) {
        Ok(r) => println!(
            "import: {} files parsed, {} new rows, {} total in {:.2} s -> {}",
            r.parsed_files,
            r.new_rows,
            r.total_rows,
            t0.elapsed().as_secs_f64(),
            paths.db_path().display()
        ),
        Err(e) => println!("import error: {e:#}"),
    }
    print_summaries(paths);
}

fn print_summaries(paths: &Paths) {
    let db = UsageDatabase::new(paths.db_path());
    for p in Period::ALL {
        let t0 = Instant::now();
        match db.summary(p) {
            Ok(s) => {
                let ms = t0.elapsed().as_millis();
                println!(
                    "== {}: ${:.2} tokens={} buckets={} unit={} ({ms} ms)",
                    p.title(),
                    s.cost,
                    s.tokens,
                    s.buckets.len(),
                    format!("{:?}", s.unit).to_lowercase()
                );
                let by: Vec<String> = s.by_provider.iter().map(|(k, v)| format!("{}=${v:.2}", k.as_str())).collect();
                println!("  byProvider: {}", by.join(" "));
                if let (Some(a), Some(b)) = (s.buckets.first(), s.buckets.last()) {
                    println!("  first: {} ${:.2}  last: {} ${:.2}", utc(a.start), a.total(), utc(b.start), b.total());
                }
            }
            Err(e) => println!("== {}: error {e:#}", p.title()),
        }
    }
}

/// Like Swift's `Date.description`.
fn utc(ms: i64) -> String {
    Utc.timestamp_millis_opt(ms).single().map(|d| d.format("%Y-%m-%d %H:%M:%S +0000").to_string()).unwrap_or_default()
}

fn json(paths: &Paths) {
    let limits: BTreeMap<&str, serde_json::Value> = ProviderId::ALL
        .into_iter()
        .map(|p| {
            let v = match limits::fetch(p, paths) {
                Ok(l) => serde_json::to_value(l).unwrap_or_default(),
                Err(e) => serde_json::json!({ "error": e.to_string() }),
            };
            (p.as_str(), v)
        })
        .collect();
    let db = UsageDatabase::new(paths.db_path());
    let usage: BTreeMap<&str, serde_json::Value> = Period::ALL
        .into_iter()
        .filter_map(|p| Some((p.title(), serde_json::to_value(db.summary(p).ok()?).ok()?)))
        .collect();
    println!("{}", serde_json::to_string_pretty(&serde_json::json!({ "limits": limits, "usage": usage })).unwrap());
}

#[derive(Default)]
struct Tally {
    files: usize,
    exact: usize,
    prefix: usize,
    missing: usize,
    t3_records: usize,
    compared: usize,
    count_mismatch: usize,
    field: BTreeMap<&'static str, usize>,
    cost_t3: f64,
    cost_burn: f64,
    tokens_t3: i64,
    tokens_burn: i64,
    examples: Vec<String>,
}

fn verify_t3(paths: &Paths) {
    let dir = paths.t3_userdata();
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map(|r| r.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    names.retain(|n| n.starts_with("usage-scan-cache") && n.ends_with(".json"));
    names.sort_by_key(|n| std::cmp::Reverse(parsers::t3_cache_version(n)));
    let Some(name) = names.first() else {
        println!("no readable T3 scan cache in {}", dir.display());
        return;
    };
    let Ok(files) = parsers::parse_t3_cache(&dir.join(name)) else {
        println!("no readable T3 scan cache in {}", dir.display());
        return;
    };
    let Some(rates) = ModelRates::load_t3_only(paths) else {
        println!("no T3 rate table");
        return;
    };
    println!(
        "T3 cache {name}: {} claude/codex transcripts, rates hash {}, {} rate keys",
        files.len(),
        &rates.hash[..12.min(rates.hash.len())],
        rates.table.len()
    );

    let price = |r: &UsageRecord| {
        let t = &r.totals;
        rates.cost(
            &r.model,
            r.rate_model.as_deref(),
            r.speed,
            t.uncached,
            t.cached,
            t.cache_creation,
            t.output,
            r.reported_cost,
        )
    };
    let mut tally: BTreeMap<String, Tally> = BTreeMap::new();
    for f in &files {
        let t = tally.entry(f.provider.clone()).or_default();
        t.files += 1;
        let Ok(meta) = std::fs::metadata(&f.path) else {
            t.missing += 1;
            continue;
        };
        let path = std::path::Path::new(&f.path);
        let parsed = if f.provider == "claude" {
            parsers::parse_claude_records(path)
        } else {
            parsers::parse_codex_records(path)
        };
        let Ok(burn) = parsed else {
            *t.field.entry("unreadable").or_default() += 1;
            continue;
        };
        let is_exact = meta.len() as i64 == f.size;
        if is_exact {
            t.exact += 1
        } else {
            t.prefix += 1
        }
        t.t3_records += f.records.len();
        if (is_exact && burn.len() != f.records.len()) || (!is_exact && burn.len() < f.records.len()) {
            t.count_mismatch += 1;
            if t.examples.len() < 8 {
                t.examples.push(format!("count {}: T3 {} Burn {}", f.path, f.records.len(), burn.len()));
            }
        }
        for (i, (a, b)) in f.records.iter().zip(&burn).enumerate() {
            t.compared += 1;
            let mut bad = Vec::new();
            if a.ts_ms != b.ts_ms {
                bad.push("ts")
            }
            if a.model != b.model {
                bad.push("model")
            }
            if a.session_id != b.session_id {
                bad.push("session")
            }
            if a.totals != b.totals {
                bad.push("tokens")
            }
            if a.speed != b.speed {
                bad.push("speed")
            }
            if a.reported_cost != b.reported_cost {
                bad.push("reportedCost")
            }
            if a.dedupe_key != b.dedupe_key {
                bad.push("dedupeKey")
            }
            for k in &bad {
                *t.field.entry(k).or_default() += 1;
            }
            if !bad.is_empty() && t.examples.len() < 8 {
                t.examples.push(format!(
                    "{} {}#{i}: T3 {:?} {:?} | Burn {:?} {:?}",
                    bad.join(","),
                    f.path,
                    a.totals,
                    a.speed,
                    b.totals,
                    b.speed
                ));
            }
            t.cost_t3 += price(a);
            t.cost_burn += price(b);
            t.tokens_t3 += a.totals.total();
            t.tokens_burn += b.totals.total();
        }
    }
    for (p, t) in &tally {
        println!(
            "== {p}: {} transcripts in T3 cache ({} size-identical, {} grown since, {} deleted from disk)",
            t.files, t.exact, t.prefix, t.missing
        );
        println!(
            "   records: T3 {}, compared {}, file count mismatches {}",
            t.t3_records, t.compared, t.count_mismatch
        );
        let fields: Vec<String> = t.field.iter().map(|(k, v)| format!("{k}={v}")).collect();
        println!("   field mismatches: {}", if fields.is_empty() { "none".into() } else { fields.join(" ") });
        println!("   tokens: T3 {} Burn {}", t.tokens_t3, t.tokens_burn);
        println!(
            "   cost (T3 rates): T3 records ${:.6}, Burn records ${:.6}, diff ${:.6}",
            t.cost_t3,
            t.cost_burn,
            t.cost_burn - t.cost_t3
        );
        for e in &t.examples {
            println!("   ! {e}");
        }
    }
}
