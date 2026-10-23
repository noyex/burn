import Foundation
import SQLite3

/// Locations and schema of Burn's own usage store.
enum UsageStore {
    static var supportDir: String { NSHomeDirectory() + "/Library/Application Support/Burn" }

    static var dbPath: String {
        ProcessInfo.processInfo.environment["BURN_DB"] ?? supportDir + "/usage.sqlite"
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS usage (
      id          TEXT PRIMARY KEY,   -- claude: msg_id:req_id, codex: codex:ts_ms:input:cache_read:output
      provider    TEXT NOT NULL,      -- claude | codex
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
      fast        INTEGER NOT NULL DEFAULT 0,
      cost_usd    REAL NOT NULL DEFAULT 0,
      origin      TEXT NOT NULL,      -- log | t3-cache | legacy
      source      TEXT
    );
    CREATE INDEX IF NOT EXISTS usage_day ON usage(day);
    CREATE INDEX IF NOT EXISTS usage_ts ON usage(ts_ms);
    CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, size INTEGER, mtime REAL);
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE VIEW IF NOT EXISTS daily AS
      SELECT day, provider, model, count(*) AS requests, count(DISTINCT session_id) AS sessions,
             sum(input) AS input, sum(cache_read) AS cache_read, sum(cache_write) AS cache_write,
             sum(output) AS output, sum(input + cache_read + cache_write + output) AS tokens,
             round(sum(cost_usd), 4) AS cost_usd
      FROM usage GROUP BY day, provider, model;
    """

    static let columns = ["id", "provider", "model", "ts_ms", "ts", "day", "session_id", "project", "input",
                          "cache_read", "cache_write", "output", "reasoning", "fast", "cost_usd", "origin", "source"]
}

/// Thin read/write SQLite connection. Not thread safe; own it from a single isolation domain.
final class SQLiteConnection {
    let db: OpaquePointer

    init(path: String, flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI) throws {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let m = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(h)
            throw UsageDatabaseError.open(m)
        }
        db = h
        sqlite3_busy_timeout(h, 5000)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw UsageDatabaseError.query(message) }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw UsageDatabaseError.query(message) }
        return s
    }

    /// Runs a prepared statement to completion (for INSERT/UPDATE), then resets it.
    func run(_ s: OpaquePointer) throws {
        defer { sqlite3_reset(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw UsageDatabaseError.query(message) }
    }

    func scalarInt(_ sql: String) throws -> Int {
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
    }

    func scalarText(_ sql: String) throws -> String? {
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let c = sqlite3_column_text(s, 0) else { return nil }
        return String(cString: c)
    }

    var message: String { String(cString: sqlite3_errmsg(db)) }
}

private let transient = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

func bindText(_ s: OpaquePointer, _ i: Int32, _ v: String?) {
    if let v { sqlite3_bind_text(s, i, v, -1, transient) } else { sqlite3_bind_null(s, i) }
}
