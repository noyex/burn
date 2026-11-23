//! Schema of Burn's own usage store. Same as `UsageStore.swift`, so a database can be compared
//! row by row with the Mac app's.

use rusqlite::{Connection, OpenFlags};
use std::path::Path;
use std::time::Duration;

/// Bump whenever parsing, ids or pricing semantics change: the importer drops and rebuilds `usage` and `files`.
pub const SCHEMA_VERSION: &str = "3";

pub const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS usage (
  id          TEXT PRIMARY KEY,   -- claude: msg_id:req_id; codex: session:ts:model:tokens#occurrence; antigravity: antigravity:field:id
  provider    TEXT NOT NULL,      -- claude | codex | antigravity
  model       TEXT,
  ts_ms       INTEGER NOT NULL,
  ts          TEXT NOT NULL,      -- local time, ISO
  day         TEXT NOT NULL,      -- local date, YYYY-MM-DD
  session_id  TEXT,
  project     TEXT,
  input       INTEGER NOT NULL DEFAULT 0,  -- uncached input
  cache_read  INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0,
  output      INTEGER NOT NULL DEFAULT 0,
  reasoning   INTEGER NOT NULL DEFAULT 0,  -- informational, already part of output
  speed       TEXT NOT NULL DEFAULT 'standard',  -- standard | fast | ultrafast
  reported_cost REAL,             -- provider-reported cost (costUSD), wins over list price
  rate_model  TEXT,               -- price this model instead of `model` (T3 scan cache)
  tier_turn   TEXT,               -- codex turn whose service tier is still unresolved
  cost_usd    REAL NOT NULL DEFAULT 0,
  origin      TEXT NOT NULL,      -- log | t3-cache (sorts by precedence)
  source      TEXT
);
CREATE INDEX IF NOT EXISTS usage_day ON usage(day);
CREATE INDEX IF NOT EXISTS usage_ts ON usage(ts_ms);
CREATE INDEX IF NOT EXISTS usage_source ON usage(source);
CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, size INTEGER, mtime REAL);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE VIEW IF NOT EXISTS daily AS
  SELECT day, provider, model, count(*) AS requests, count(DISTINCT session_id) AS sessions,
         sum(input) AS input, sum(cache_read) AS cache_read, sum(cache_write) AS cache_write,
         sum(output) AS output, sum(input + cache_read + cache_write + output) AS tokens,
         round(sum(cost_usd), 4) AS cost_usd
  FROM usage GROUP BY day, provider, model;
";

pub const COLUMNS: [&str; 20] = [
    "id",
    "provider",
    "model",
    "ts_ms",
    "ts",
    "day",
    "session_id",
    "project",
    "input",
    "cache_read",
    "cache_write",
    "output",
    "reasoning",
    "speed",
    "reported_cost",
    "rate_model",
    "tier_turn",
    "cost_usd",
    "origin",
    "source",
];

pub fn open_rw(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    Ok(conn)
}

pub fn open_ro(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    conn.busy_timeout(Duration::from_secs(3))?;
    Ok(conn)
}
