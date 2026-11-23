//! Port of `UsageImporter.swift`: imports Claude Code / Codex usage from local session logs (and
//! T3 Code's scan caches) into Burn's own store. Blocking; run it on a worker thread.

use crate::parsers::{self, Speed, UsageRow};
use crate::paths::Paths;
use crate::rates::ModelRates;
use crate::store::{self, COLUMNS, SCHEMA, SCHEMA_VERSION};
use crate::tier;
use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, Statement, params};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::mpsc;
use std::time::UNIX_EPOCH;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImportProgress {
    pub done: usize,
    pub total: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImportResult {
    pub parsed_files: usize,
    pub new_rows: i64,
    pub total_rows: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Claude,
    Codex,
    Antigravity,
}

#[derive(Clone, Debug)]
struct Job {
    path: PathBuf,
    /// The path as stored in the database (`source`, `files.path`, ids).
    key: String,
    size: i64,
    mtime: f64,
    kind: Kind,
}

const CONCURRENCY: usize = 6;

/// A row replaces an existing one with the same id only if it ranks better: log before T3 cache, then the
/// earliest timestamp, then the lowest source path; a re-import of the same source always overwrites.
/// Keeps T3's "first occurrence wins" deterministic whatever order files finish parsing in.
fn upsert_sql() -> String {
    let rest = &COLUMNS[1..];
    format!(
        "INSERT INTO usage ({}) VALUES ({}) ON CONFLICT(id) DO UPDATE SET {} WHERE ({}) AND (excluded.origin < usage.origin \
         OR (excluded.origin = usage.origin AND (excluded.source = usage.source OR excluded.ts_ms < usage.ts_ms \
         OR (excluded.ts_ms = usage.ts_ms AND excluded.source < usage.source))))",
        COLUMNS.join(","),
        COLUMNS.iter().map(|_| "?").collect::<Vec<_>>().join(","),
        rest.iter().map(|c| format!("{c}=excluded.{c}")).collect::<Vec<_>>().join(","),
        rest.iter().map(|c| format!("excluded.{c} IS NOT usage.{c}")).collect::<Vec<_>>().join(" OR "),
    )
}

/// Runs a full import with the current rate table.
pub fn run(paths: &Paths, progress: &(dyn Fn(ImportProgress) + Sync)) -> Result<ImportResult> {
    let rates = ModelRates::load(paths);
    run_with_rates(paths, &rates, progress)
}

pub fn run_with_rates(
    paths: &Paths,
    rates: &ModelRates,
    progress: &(dyn Fn(ImportProgress) + Sync),
) -> Result<ImportResult> {
    let db_path = paths.db_path();
    if let Some(dir) = db_path.parent() {
        fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let mut conn = store::open_rw(&db_path).context("open usage database")?;
    conn.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
    conn.execute_batch("PRAGMA synchronous=NORMAL")?;
    migrate(&mut conn)?;
    let before: i64 = conn.query_row("SELECT count(*) FROM usage", [], |r| r.get(0))?;

    let known = known_files(&conn)?;
    let mut all = discover(&paths.claude_projects(), Kind::Claude);
    all.extend(discover(&paths.codex_sessions(), Kind::Codex));
    all.extend(discover_antigravity(paths));
    let jobs: Vec<Job> = all.iter().filter(|j| known.get(&j.key) != Some(&(j.size, j.mtime))).cloned().collect();
    let caches = t3_caches(&paths.t3_userdata());
    let total = jobs.len() + caches.len();
    let mut done = 0;
    progress(ImportProgress { done: 0, total });

    let result = import_files(&conn, rates, &jobs, &all, &caches, total, &mut done, progress);
    if result.is_err() {
        // A no-op error when no transaction is open.
        let _ = conn.execute_batch("ROLLBACK");
    }
    let parsed_files = result?;

    resolve_tiers(&mut conn, paths, rates)?;
    reprice(&mut conn, rates)?;
    let after: i64 = conn.query_row("SELECT count(*) FROM usage", [], |r| r.get(0))?;
    let _ = conn.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |_| Ok(()));
    Ok(ImportResult { parsed_files, new_rows: after - before, total_rows: after })
}

#[allow(clippy::too_many_arguments)]
fn import_files(
    conn: &Connection,
    rates: &ModelRates,
    jobs: &[Job],
    all: &[Job],
    caches: &[Job],
    total: usize,
    done: &mut usize,
    progress: &(dyn Fn(ImportProgress) + Sync),
) -> Result<usize> {
    let mut upsert = conn.prepare(&upsert_sql())?;
    let mut file_stmt = conn.prepare("INSERT OR REPLACE INTO files VALUES (?,?,?)")?;
    let mut clear = conn.prepare("DELETE FROM usage WHERE source = ? AND origin = 'log'")?;
    let mut parsed_files = 0;

    // Logs: parsed concurrently, written serially. Raw logs are the source of truth, so a changed file replaces its rows.
    let mut batch = Batch::default();
    let next = Mutex::new(jobs.iter());
    std::thread::scope(|scope| -> Result<()> {
        let (tx, rx) = mpsc::sync_channel::<(&Job, Option<Vec<UsageRow>>)>(CONCURRENCY * 2);
        for _ in 0..CONCURRENCY.min(jobs.len()) {
            let tx = tx.clone();
            let next = &next;
            scope.spawn(move || {
                loop {
                    let Some(job) = next.lock().map(|mut it| it.next()).ok().flatten() else { return };
                    let rows = parse_job(job, rates);
                    // The writer stopped (error): nothing left to do.
                    if tx.send((job, rows)).is_err() {
                        return;
                    }
                }
            });
        }
        drop(tx);
        for (job, rows) in rx {
            *done += 1;
            if let Some(rows) = rows {
                batch.open(conn)?;
                clear.execute([&job.key])?;
                for row in &rows {
                    bind_row(&mut upsert, row)?;
                }
                file_stmt.execute(params![job.key, job.size, job.mtime])?;
                parsed_files += 1;
                batch.file_done(conn)?;
            }
            progress(ImportProgress { done: *done, total });
        }
        Ok(())
    })?;
    batch.commit(conn)?;

    // T3 caches, newest format first. They only contribute transcripts that are gone from disk (T3 does the same
    // for retained history), and never override log rows. Their rows depend only on the cache files and on which
    // log paths exist, so nothing is re-read when neither changed and no log was (re)parsed.
    let mut covered: HashSet<String> = all.iter().map(|j| j.key.clone()).collect();
    let mut sig_parts: Vec<String> =
        caches.iter().map(|c| format!("{}|{}|{}", c.key, c.size, swift_double(c.mtime))).collect();
    sig_parts.push("--".into());
    let mut sorted: Vec<&String> = covered.iter().collect();
    sorted.sort();
    sig_parts.extend(sorted.into_iter().cloned());
    let cache_sig = digest(&sig_parts);
    let stored: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key='cache_sig'", [], |r| r.get(0)).optional()?;
    if jobs.is_empty() && stored.as_deref() == Some(cache_sig.as_str()) {
        *done += caches.len();
        progress(ImportProgress { done: *done, total });
        return Ok(parsed_files);
    }
    conn.execute_batch("BEGIN")?;
    for c in caches {
        if let Ok(files) = parsers::parse_t3_cache(&c.path) {
            for f in files.iter().filter(|f| !covered.contains(&f.path)) {
                let project = (f.provider == "claude").then(|| parent_name(&f.path)).flatten();
                for row in parsers::make_rows(&f.records, &f.path, "t3-cache", project.as_deref(), rates) {
                    bind_row(&mut upsert, &row)?;
                }
            }
            // A path seen in a newer cache is not taken again from an older one.
            covered.extend(files.into_iter().map(|f| f.path));
            parsed_files += 1;
        }
        *done += 1;
        progress(ImportProgress { done: *done, total });
    }
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('cache_sig', ?)", [&cache_sig])?;
    conn.execute_batch("COMMIT")?;
    Ok(parsed_files)
}

fn parse_job(job: &Job, rates: &ModelRates) -> Option<Vec<UsageRow>> {
    let records = match job.kind {
        Kind::Claude => parsers::parse_claude_records(&job.path).ok()?,
        Kind::Codex => parsers::parse_codex_records(&job.path).ok()?,
        Kind::Antigravity => crate::antigravity::parse_database(&job.path)?,
    };
    let project = match job.kind {
        Kind::Claude => parent_name(&job.key),
        Kind::Codex | Kind::Antigravity => None,
    };
    Some(parsers::make_rows(&records, &job.key, "log", project.as_deref(), rates))
}

/// Name of the directory holding `path` (Claude's per-project folder).
fn parent_name(path: &str) -> Option<String> {
    Path::new(path).parent()?.file_name().map(|n| n.to_string_lossy().into_owned())
}

fn bind_row(stmt: &mut Statement<'_>, r: &UsageRow) -> rusqlite::Result<usize> {
    stmt.execute(params![
        r.id,
        r.provider,
        r.model,
        r.ts_ms,
        r.ts,
        r.day,
        r.session,
        r.project,
        r.totals.uncached,
        r.totals.cached,
        r.totals.cache_creation,
        r.totals.output,
        r.totals.reasoning,
        r.speed.as_str(),
        r.reported_cost,
        r.rate_model,
        r.tier_turn,
        r.cost,
        r.origin,
        r.source,
    ])
}

/// Drops everything derived from logs when the parsing / pricing semantics changed.
fn migrate(conn: &mut Connection) -> Result<()> {
    conn.execute_batch("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")?;
    let version: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get(0)).optional()?;
    if version.as_deref() != Some(SCHEMA_VERSION) {
        let tx = conn.transaction()?;
        tx.execute_batch(
            "DROP VIEW IF EXISTS daily; DROP TABLE IF EXISTS usage; DROP TABLE IF EXISTS files; DELETE FROM meta",
        )?;
        tx.execute_batch(SCHEMA)?;
        tx.execute("INSERT INTO meta VALUES ('schema_version', ?)", [SCHEMA_VERSION])?;
        tx.commit()?;
    }
    conn.execute_batch(SCHEMA)?;
    Ok(())
}

struct Pending {
    id: String,
    request: tier::Request,
    rate_model: Option<String>,
    tokens: [i64; 4],
    reported: Option<f64>,
}

/// Fills in the speed of Codex turns that carry no `thread_settings_applied`, from T3's database.
fn resolve_tiers(conn: &mut Connection, paths: &Paths, rates: &ModelRates) -> Result<()> {
    let pending: Vec<Pending> = {
        let mut find = conn.prepare(
            "SELECT id, session_id, tier_turn, model, rate_model, input, cache_read, cache_write, output, reported_cost \
             FROM usage WHERE tier_turn IS NOT NULL AND session_id IS NOT NULL",
        )?;
        find.query_map([], |r| {
            Ok(Pending {
                id: r.get(0)?,
                request: tier::Request {
                    session: r.get(1)?,
                    turn: r.get(2)?,
                    model: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                },
                rate_model: r.get(4)?,
                tokens: [r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?],
                reported: r.get(9)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?
    };
    if pending.is_empty() {
        return Ok(());
    }
    // Only ask T3 again when its database changed or the set of unresolved rows did.
    let signature = |rows: &[&Pending]| {
        let mut ids: Vec<&str> = rows.iter().map(|p| p.id.as_str()).collect();
        ids.sort();
        let mut parts = vec![tier::db_stamp(paths)];
        parts.extend(ids.into_iter().map(String::from));
        digest(&parts)
    };
    let all: Vec<&Pending> = pending.iter().collect();
    let stored: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key='tier_sig'", [], |r| r.get(0)).optional()?;
    if stored.as_deref() == Some(signature(&all).as_str()) {
        return Ok(());
    }
    let mut requests: Vec<tier::Request> =
        pending.iter().map(|p| p.request.clone()).collect::<HashSet<_>>().into_iter().collect();
    requests.sort_by(|a, b| a.turn.cmp(&b.turn));
    let resolved: HashMap<tier::Request, Speed> = tier::resolve(paths, &requests);
    let remaining: Vec<&Pending> = pending.iter().filter(|p| !resolved.contains_key(&p.request)).collect();
    let sig = signature(&remaining);
    let tx = conn.transaction()?;
    if !resolved.is_empty() {
        let mut update = tx.prepare("UPDATE usage SET speed=?, tier_turn=NULL, cost_usd=? WHERE id=?")?;
        for p in &pending {
            let Some(&speed) = resolved.get(&p.request) else { continue };
            let [u, c, w, o] = p.tokens;
            let cost = rates.cost(&p.request.model, p.rate_model.as_deref(), speed, u, c, w, o, p.reported);
            update.execute(params![speed.as_str(), cost, p.id])?;
        }
    }
    tx.execute("INSERT OR REPLACE INTO meta VALUES ('tier_sig', ?)", [&sig])?;
    tx.commit()?;
    Ok(())
}

/// Recomputes every stored cost when the rate table (or T3's price overrides) changed since the last import.
fn reprice(conn: &mut Connection, rates: &ModelRates) -> Result<()> {
    let stored: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key='rates_hash'", [], |r| r.get(0)).optional()?;
    if stored.as_deref() == Some(rates.hash.as_str()) {
        return Ok(());
    }
    // An unusable table (offline, no cache) must not zero out costs that were priced earlier. Rows imported now
    // are unpriced, so forget the stored hash: the next run with real rates re-prices everything.
    if rates.table.is_empty() {
        conn.execute_batch("DELETE FROM meta WHERE key='rates_hash'")?;
        return Ok(());
    }
    let changes: Vec<(String, f64)> = {
        let mut find = conn.prepare(
            "SELECT id, model, rate_model, speed, input, cache_read, cache_write, output, reported_cost, cost_usd FROM usage",
        )?;
        let rows = find.query_map([], |r| {
            let model: Option<String> = r.get(1)?;
            let rate_model: Option<String> = r.get(2)?;
            let speed: Option<String> = r.get(3)?;
            let cost = rates.cost(
                model.as_deref().unwrap_or(""),
                rate_model.as_deref(),
                speed.as_deref().and_then(Speed::parse).unwrap_or(Speed::Standard),
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
                r.get(7)?,
                r.get(8)?,
            );
            let old: f64 = r.get(9)?;
            Ok((r.get::<_, String>(0)?, cost, old))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (id, cost, old) = row?;
            if cost != old {
                out.push((id, cost));
            }
        }
        out
    };
    let tx = conn.transaction()?;
    {
        let mut update = tx.prepare("UPDATE usage SET cost_usd=? WHERE id=?")?;
        for (id, cost) in &changes {
            update.execute(params![cost, id])?;
        }
    }
    tx.execute("INSERT OR REPLACE INTO meta VALUES ('rates_hash', ?)", [&rates.hash])?;
    tx.commit()?;
    Ok(())
}

/// Groups several files into one transaction.
#[derive(Default)]
struct Batch {
    pending: usize,
}

impl Batch {
    fn open(&mut self, conn: &Connection) -> rusqlite::Result<()> {
        if self.pending == 0 {
            conn.execute_batch("BEGIN")?;
            self.pending = 1;
        }
        Ok(())
    }

    fn file_done(&mut self, conn: &Connection) -> rusqlite::Result<()> {
        self.pending += 1;
        if self.pending > 40 {
            self.commit(conn)?;
        }
        Ok(())
    }

    fn commit(&mut self, conn: &Connection) -> rusqlite::Result<()> {
        if self.pending > 0 {
            conn.execute_batch("COMMIT")?;
            self.pending = 0;
        }
        Ok(())
    }
}

fn digest(parts: &[String]) -> String {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p.as_bytes());
        h.update([0u8]);
    }
    crate::util::hex(&h.finalize())
}

/// Shortest round-trip form, like Swift's `"\(double)"` (only used inside signatures).
fn swift_double(v: f64) -> String {
    format!("{v:?}")
}

fn known_files(conn: &Connection) -> rusqlite::Result<HashMap<String, (i64, f64)>> {
    let mut s = conn.prepare("SELECT path, size, mtime FROM files")?;
    let rows = s.query_map([], |r| Ok((r.get::<_, String>(0)?, (r.get::<_, i64>(1)?, r.get::<_, f64>(2)?))))?;
    rows.collect()
}

fn file_stat(path: &Path) -> Option<(i64, f64)> {
    let m = fs::metadata(path).ok()?;
    let t = m.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some((m.len() as i64, t.as_secs() as f64 + f64::from(t.subsec_nanos()) / 1e9))
}

/// Every `*.jsonl` below `root`, hidden directories included (T3 walks them too). Symlinked folders are not followed.
fn discover(root: &Path, kind: Kind) -> Vec<Job> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let path = e.path();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|x| x == "jsonl")
                && let Some((size, mtime)) = file_stat(&path)
            {
                out.push(Job { key: path.to_string_lossy().into_owned(), path, size, mtime, kind });
            }
        }
    }
    out
}

/// Antigravity conversation `.db` files; fingerprint includes `-wal` so live turns trigger re-import.
fn discover_antigravity(paths: &Paths) -> Vec<Job> {
    let mut seen: HashSet<PathBuf> = HashSet::new();
    let mut out = Vec::new();
    for root in crate::antigravity::conversation_dirs(paths) {
        let mut stack = vec![root];
        while let Some(dir) = stack.pop() {
            let Ok(entries) = fs::read_dir(&dir) else { continue };
            for e in entries.flatten() {
                let path = e.path();
                let Ok(ft) = e.file_type() else { continue };
                if ft.is_symlink() {
                    continue;
                }
                if ft.is_dir() {
                    stack.push(path);
                } else if path.extension().is_some_and(|x| x == "db") {
                    let canonical = fs::canonicalize(&path).unwrap_or(path);
                    if !seen.insert(canonical.clone()) {
                        continue;
                    }
                    let Some((size, mtime)) = file_stat(&canonical) else { continue };
                    let mut wal_os = canonical.as_os_str().to_os_string();
                    wal_os.push("-wal");
                    let wal = file_stat(Path::new(&wal_os));
                    out.push(Job {
                        key: canonical.to_string_lossy().into_owned(),
                        path: canonical,
                        size: size + wal.map_or(0, |w| w.0),
                        mtime: mtime.max(wal.map_or(0.0, |w| w.1)),
                        kind: Kind::Antigravity,
                    });
                }
            }
        }
    }
    out
}

/// T3 scan caches, newest format first.
fn t3_caches(dir: &Path) -> Vec<Job> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    let mut names: Vec<String> = entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("usage-scan-cache") && n.ends_with(".json"))
        .collect();
    names.sort_by(|a, b| (parsers::t3_cache_version(b), b).cmp(&(parsers::t3_cache_version(a), a)));
    names
        .into_iter()
        .filter_map(|n| {
            let path = dir.join(&n);
            let (size, mtime) = file_stat(&path)?;
            Some(Job { key: path.to_string_lossy().into_owned(), path, size, mtime, kind: Kind::Claude })
        })
        .collect()
}
