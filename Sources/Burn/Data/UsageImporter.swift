import Foundation
import SQLite3

struct ImportProgress: Sendable {
    let done: Int
    let total: Int
}

/// Imports Claude Code / Codex usage from local session logs (and T3 Code's caches) into Burn's own store.
actor UsageImporter {
    static let shared = UsageImporter()

    private struct Job: Sendable {
        let path: String
        let size: Int64
        let mtime: Double
        let kind: Kind
        enum Kind: Sendable { case claude, codex }
    }

    private struct Parsed: Sendable {
        let job: Job
        let rows: [UsageRow]?
    }

    private static let columns = UsageStore.columns.joined(separator: ",")
    private static let placeholders = UsageStore.columns.map { _ in "?" }.joined(separator: ",")
    /// A row replaces an existing one with the same id only if it ranks better: log before T3 cache, then the
    /// earliest timestamp, then the lowest source path; a re-import of the same source always overwrites.
    /// Keeps T3's "first occurrence wins" deterministic whatever order files finish parsing in.
    private static let upsert = "INSERT INTO usage (\(columns)) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET "
        + UsageStore.columns.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        + " WHERE excluded.origin < usage.origin OR (excluded.origin = usage.origin AND (excluded.source = usage.source"
        + " OR excluded.ts_ms < usage.ts_ms OR (excluded.ts_ms = usage.ts_ms AND excluded.source < usage.source)))"
    private static let concurrency = 6

    func run(progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> (parsedFiles: Int, newRows: Int, totalRows: Int) {
        try FileManager.default.createDirectory(atPath: (UsageStore.dbPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let conn = try SQLiteConnection(path: UsageStore.dbPath)
        _ = try conn.scalarText("PRAGMA journal_mode=WAL")
        try conn.exec("PRAGMA synchronous=NORMAL")
        try migrate(conn)
        let before = try conn.scalarInt("SELECT count(*) FROM usage")

        let rates = await ModelRates.load()
        let known = try knownFiles(conn)
        let home = NSHomeDirectory()
        let all = Self.discover(home + "/.claude/projects", kind: .claude) + Self.discover(home + "/.codex/sessions", kind: .codex)
        let jobs = all.filter { j in known[j.path].map { $0 != (j.size, j.mtime) } ?? true }
        let caches = Self.t3Caches(in: home + "/.t3/userdata")
        let total = jobs.count + caches.count
        var done = 0
        progress(ImportProgress(done: 0, total: total))

        let upsertStmt = try conn.prepare(Self.upsert)
        let fileStmt = try conn.prepare("INSERT OR REPLACE INTO files VALUES (?,?,?)")
        let clearStmt = try conn.prepare("DELETE FROM usage WHERE source = ? AND origin = 'log'")
        defer { sqlite3_finalize(upsertStmt); sqlite3_finalize(fileStmt); sqlite3_finalize(clearStmt) }
        let batch = Batch(conn)

        // Logs: parsed concurrently, written serially. Raw logs are the source of truth, so a changed file replaces its rows.
        var parsedFiles = 0
        try await withThrowingTaskGroup(of: Parsed.self) { group in
            var iterator = jobs.makeIterator()
            func spawn() {
                guard let job = iterator.next() else { return }
                group.addTask {
                    let records = job.kind == .claude ? try? parseClaudeRecords(path: job.path)
                                                      : try? parseCodexRecords(path: job.path)
                    let project = job.kind == .claude ? URL(fileURLWithPath: job.path).deletingLastPathComponent().lastPathComponent : nil
                    return Parsed(job: job, rows: records.map { makeRows($0, path: job.path, origin: "log", project: project, rates: rates) })
                }
            }
            for _ in 0..<Self.concurrency { spawn() }
            while let r = try await group.next() {
                spawn()
                done += 1
                if let rows = r.rows {
                    try batch.open()
                    bindText(clearStmt, 1, r.job.path)
                    try conn.run(clearStmt)
                    for row in rows { try Self.bind(upsertStmt, row); try conn.run(upsertStmt) }
                    try Self.recordFile(fileStmt, r.job.path, r.job.size, r.job.mtime, conn)
                    parsedFiles += 1
                    try batch.fileDone()
                }
                progress(ImportProgress(done: done, total: total))
            }
        }
        try batch.commit()

        // T3 caches, newest format first. They only contribute transcripts that are gone from disk (T3 does the same
        // for retained history), and never override log rows. Cheap, so always re-read in full.
        var covered = Set(all.map(\.path))
        try conn.exec("BEGIN")
        for c in caches {
            if let files = try? parseT3Cache(path: c.path) {
                for f in files where !covered.contains(f.path) {
                    let project = f.provider == "claude" ? URL(fileURLWithPath: f.path).deletingLastPathComponent().lastPathComponent : nil
                    for row in makeRows(f.records, path: f.path, origin: "t3-cache", project: project, rates: rates) {
                        try Self.bind(upsertStmt, row); try conn.run(upsertStmt)
                    }
                }
                // A path seen in a newer cache is not taken again from an older one.
                covered.formUnion(files.map(\.path))
                parsedFiles += 1
            }
            done += 1
            progress(ImportProgress(done: done, total: total))
        }
        try conn.exec("COMMIT")

        try resolveTiers(conn, rates)
        try reprice(conn, rates)
        let after = try conn.scalarInt("SELECT count(*) FROM usage")
        _ = try? conn.scalarText("PRAGMA wal_checkpoint(PASSIVE)")
        return (parsedFiles, after - before, after)
    }

    // MARK: - Steps

    /// Drops everything derived from logs when the parsing / pricing semantics changed (old rows were computed
    /// differently, and the old Python importer's database is deliberately not imported).
    private func migrate(_ conn: SQLiteConnection) throws {
        try conn.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        if try conn.scalarText("SELECT value FROM meta WHERE key='schema_version'") != UsageStore.schemaVersion {
            try conn.exec("BEGIN")
            do {
                try conn.exec("DROP VIEW IF EXISTS daily; DROP TABLE IF EXISTS usage; DROP TABLE IF EXISTS files; DELETE FROM meta")
                try conn.exec(UsageStore.schema)
                try conn.exec("INSERT INTO meta VALUES ('schema_version', '\(UsageStore.schemaVersion)')")
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
        try conn.exec(UsageStore.schema)
    }

    /// Fills in the speed of Codex turns that carry no `thread_settings_applied`, from T3's database.
    private func resolveTiers(_ conn: SQLiteConnection, _ rates: ModelRates) throws {
        let find = try conn.prepare("SELECT id, session_id, tier_turn, model, rate_model, input, cache_read, cache_write, output, reported_cost FROM usage WHERE tier_turn IS NOT NULL AND session_id IS NOT NULL")
        struct Pending { let id, session, turn, model: String; let rateModel: String?; let t: [Int64]; let reported: Double? }
        var pending: [Pending] = []
        while sqlite3_step(find) == SQLITE_ROW {
            func t(_ i: Int32) -> String? { sqlite3_column_text(find, i).map { String(cString: $0) } }
            pending.append(Pending(id: t(0)!, session: t(1)!, turn: t(2)!, model: t(3) ?? "", rateModel: t(4),
                                   t: (5...8).map { sqlite3_column_int64(find, Int32($0)) },
                                   reported: sqlite3_column_type(find, 9) == SQLITE_NULL ? nil : sqlite3_column_double(find, 9)))
        }
        sqlite3_finalize(find)
        guard !pending.isEmpty else { return }
        let resolved = CodexTierResolver.resolve(Set(pending.map { CodexTierResolver.Request(session: $0.session, turn: $0.turn, model: $0.model) }).sorted { $0.turn < $1.turn })
        guard !resolved.isEmpty else { return }
        let update = try conn.prepare("UPDATE usage SET speed=?, tier_turn=NULL, cost_usd=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        try conn.exec("BEGIN")
        do {
            for p in pending {
                guard let speed = resolved[CodexTierResolver.Request(session: p.session, turn: p.turn, model: p.model)] else { continue }
                let cost = rates.cost(model: p.model, rateModel: p.rateModel, speed: speed, uncached: p.t[0], cached: p.t[1],
                                      cacheCreation: p.t[2], output: p.t[3], reported: p.reported)
                bindText(update, 1, speed.rawValue); sqlite3_bind_double(update, 2, cost); bindText(update, 3, p.id)
                try conn.run(update)
            }
            try conn.exec("COMMIT")
        } catch {
            try? conn.exec("ROLLBACK")
            throw error
        }
    }

    /// Recomputes every stored cost when the rate table (or T3's price overrides) changed since the last import.
    private func reprice(_ conn: SQLiteConnection, _ rates: ModelRates) throws {
        if try conn.scalarText("SELECT value FROM meta WHERE key='rates_hash'") == rates.hash { return }
        // An unusable table (offline, no cache) must not zero out costs that were priced earlier.
        if rates.table.isEmpty { return }
        let find = try conn.prepare("SELECT id, model, rate_model, speed, input, cache_read, cache_write, output, reported_cost, cost_usd FROM usage")
        let update = try conn.prepare("UPDATE usage SET cost_usd=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        var changes: [(String, Double)] = []
        while sqlite3_step(find) == SQLITE_ROW {
            func t(_ i: Int32) -> String? { sqlite3_column_text(find, i).map { String(cString: $0) } }
            let cost = rates.cost(
                model: t(1) ?? "", rateModel: t(2), speed: Speed(rawValue: t(3) ?? "") ?? .standard,
                uncached: sqlite3_column_int64(find, 4), cached: sqlite3_column_int64(find, 5),
                cacheCreation: sqlite3_column_int64(find, 6), output: sqlite3_column_int64(find, 7),
                reported: sqlite3_column_type(find, 8) == SQLITE_NULL ? nil : sqlite3_column_double(find, 8))
            if cost != sqlite3_column_double(find, 9) { changes.append((t(0)!, cost)) }
        }
        sqlite3_finalize(find)
        try conn.exec("BEGIN")
        do {
            for (id, cost) in changes {
                sqlite3_bind_double(update, 1, cost); bindText(update, 2, id)
                try conn.run(update)
            }
            try conn.exec("INSERT OR REPLACE INTO meta VALUES ('rates_hash', '\(rates.hash)')")
            try conn.exec("COMMIT")
        } catch {
            try? conn.exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Helpers

    private func knownFiles(_ conn: SQLiteConnection) throws -> [String: (Int64, Double)] {
        let s = try conn.prepare("SELECT path, size, mtime FROM files")
        defer { sqlite3_finalize(s) }
        var out: [String: (Int64, Double)] = [:]
        while sqlite3_step(s) == SQLITE_ROW, let c = sqlite3_column_text(s, 0) {
            out[String(cString: c)] = (sqlite3_column_int64(s, 1), sqlite3_column_double(s, 2))
        }
        return out
    }

    private static func fileStat(_ path: String) -> (Int64, Double)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (Int64(st.st_size), Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Every `*.jsonl` below `root`, hidden directories included (T3 walks them too).
    private static func discover(_ root: String, kind: Job.Kind) -> [Job] {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { return [] }
        var out: [Job] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let (size, mtime) = fileStat(url.path) else { continue }
            out.append(Job(path: url.path, size: size, mtime: mtime, kind: kind))
        }
        return out
    }

    /// T3 scan caches, newest format first.
    private static func t3Caches(in dir: String) -> [Job] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("usage-scan-cache") && $0.hasSuffix(".json") }
            .sorted { (t3CacheVersion($0), $0) > (t3CacheVersion($1), $1) }
            .compactMap { n -> Job? in
                let p = dir + "/" + n
                return fileStat(p).map { Job(path: p, size: $0.0, mtime: $0.1, kind: .claude) }
            }
    }

    private static func recordFile(_ s: OpaquePointer, _ path: String, _ size: Int64, _ mtime: Double,
                                   _ conn: SQLiteConnection) throws {
        bindText(s, 1, path)
        sqlite3_bind_int64(s, 2, size)
        sqlite3_bind_double(s, 3, mtime)
        try conn.run(s)
    }

    private static func bind(_ s: OpaquePointer, _ r: UsageRow) throws {
        bindText(s, 1, r.id); bindText(s, 2, r.provider); bindText(s, 3, r.model)
        sqlite3_bind_int64(s, 4, r.tsMs); bindText(s, 5, r.ts); bindText(s, 6, r.day)
        bindText(s, 7, r.session); bindText(s, 8, r.project)
        sqlite3_bind_int64(s, 9, r.totals.uncached); sqlite3_bind_int64(s, 10, r.totals.cached)
        sqlite3_bind_int64(s, 11, r.totals.cacheCreation); sqlite3_bind_int64(s, 12, r.totals.output)
        sqlite3_bind_int64(s, 13, r.totals.reasoning); bindText(s, 14, r.speed.rawValue)
        if let c = r.reportedCost { sqlite3_bind_double(s, 15, c) } else { sqlite3_bind_null(s, 15) }
        bindText(s, 16, r.rateModel); bindText(s, 17, r.tierTurn)
        sqlite3_bind_double(s, 18, r.cost); bindText(s, 19, r.origin); bindText(s, 20, r.source)
    }
}

/// Groups several files into one transaction.
private final class Batch {
    private let conn: SQLiteConnection
    private var pending = 0
    init(_ conn: SQLiteConnection) { self.conn = conn }
    func open() throws { if pending == 0 { try conn.exec("BEGIN"); pending = 1 } }
    func fileDone() throws { pending += 1; if pending > 40 { try commit() } }
    func commit() throws { if pending > 0 { try conn.exec("COMMIT"); pending = 0 } }
}
