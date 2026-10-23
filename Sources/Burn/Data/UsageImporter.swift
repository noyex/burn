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
    private static let upsert = "INSERT INTO usage (\(columns)) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET "
        + UsageStore.columns.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ",")
    private static let insertIgnore = "INSERT OR IGNORE INTO usage (\(columns)) VALUES (\(placeholders))"
    private static let concurrency = 6

    func run(progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> (parsedFiles: Int, newRows: Int, totalRows: Int) {
        try FileManager.default.createDirectory(atPath: (UsageStore.dbPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let conn = try SQLiteConnection(path: UsageStore.dbPath)
        _ = try conn.scalarText("PRAGMA journal_mode=WAL")
        try conn.exec("PRAGMA synchronous=NORMAL")
        try conn.exec(UsageStore.schema)
        let before = try conn.scalarInt("SELECT count(*) FROM usage")

        try importLegacy(conn)

        let rates = await ModelRates.load()
        let known = try knownFiles(conn)
        let home = NSHomeDirectory()
        let jobs = Self.jobs(in: home + "/.claude/projects", kind: .claude, known: known)
            + Self.jobs(in: home + "/.codex/sessions", kind: .codex, known: known)
        let caches = Self.t3Caches(in: home + "/.t3/userdata", known: known)
        let total = jobs.count + caches.count
        var done = 0
        progress(ImportProgress(done: 0, total: total))

        let upsertStmt = try conn.prepare(Self.upsert)
        let fileStmt = try conn.prepare("INSERT OR REPLACE INTO files VALUES (?,?,?)")
        defer { sqlite3_finalize(upsertStmt); sqlite3_finalize(fileStmt) }
        let batch = Batch(conn)

        // Logs: parsed concurrently, written serially. Raw logs are the source of truth, so they overwrite.
        var parsedFiles = 0
        try await withThrowingTaskGroup(of: Parsed.self) { group in
            var iterator = jobs.makeIterator()
            func spawn() {
                guard let job = iterator.next() else { return }
                group.addTask {
                    let rows = job.kind == .claude ? try? parseClaude(path: job.path, rates: rates)
                                                   : try? parseCodex(path: job.path, rates: rates)
                    return Parsed(job: job, rows: rows)
                }
            }
            for _ in 0..<Self.concurrency { spawn() }
            while let r = try await group.next() {
                spawn()
                done += 1
                if let rows = r.rows {
                    try batch.open()
                    for row in rows { try Self.bind(upsertStmt, row); try conn.run(upsertStmt) }
                    try Self.recordFile(fileStmt, r.job.path, r.job.size, r.job.mtime, conn)
                    parsedFiles += 1
                    try batch.fileDone()
                }
                progress(ImportProgress(done: done, total: total))
            }
        }
        try batch.commit()

        // T3 caches, oldest first, never overwriting existing rows.
        let insertStmt = try conn.prepare(Self.insertIgnore)
        defer { sqlite3_finalize(insertStmt) }
        for c in caches {
            if let rows = try? parseT3Cache(path: c.path, rates: rates) {
                try conn.exec("BEGIN")
                for row in rows { try Self.bind(insertStmt, row); try conn.run(insertStmt) }
                try Self.recordFile(fileStmt, c.path, c.size, c.mtime, conn)
                try conn.exec("COMMIT")
                parsedFiles += 1
            }
            done += 1
            progress(ImportProgress(done: done, total: total))
        }

        try reprice(conn, rates)
        let after = try conn.scalarInt("SELECT count(*) FROM usage")
        _ = try? conn.scalarText("PRAGMA wal_checkpoint(PASSIVE)")
        return (parsedFiles, after - before, after)
    }

    // MARK: - Steps

    /// One-time import of the old Python importer's database (`~/.t3-usage`), so history from deleted logs survives.
    private func importLegacy(_ conn: SQLiteConnection) throws {
        let legacy = NSHomeDirectory() + "/.t3-usage/usage.sqlite"
        guard ProcessInfo.processInfo.environment["BURN_SKIP_LEGACY"] == nil,
              try conn.scalarText("SELECT value FROM meta WHERE key='legacy_imported'") == nil,
              FileManager.default.fileExists(atPath: legacy) else { return }
        var url = URLComponents()
        url.scheme = "file"; url.path = legacy; url.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = url.string else { return }
        let escaped = uri.replacingOccurrences(of: "'", with: "''")
        try conn.exec("ATTACH DATABASE '\(escaped)' AS legacy")
        defer { try? conn.exec("DETACH DATABASE legacy") }
        let cols = UsageStore.columns.joined(separator: ",")
        try conn.exec("BEGIN")
        do {
            try conn.exec("INSERT OR IGNORE INTO usage (\(cols)) SELECT \(cols) FROM legacy.usage")
            try conn.exec("INSERT OR REPLACE INTO meta VALUES ('legacy_imported', '1')")
            try conn.exec("COMMIT")
        } catch {
            try? conn.exec("ROLLBACK")
            throw error
        }
    }

    /// Recomputes cost for rows imported before their model had a known rate.
    private func reprice(_ conn: SQLiteConnection, _ rates: ModelRates) throws {
        let find = try conn.prepare("SELECT DISTINCT model FROM usage WHERE cost_usd = 0 AND model IS NOT NULL")
        var models: [String] = []
        while sqlite3_step(find) == SQLITE_ROW, let c = sqlite3_column_text(find, 0) { models.append(String(cString: c)) }
        sqlite3_finalize(find)
        let priced = models.compactMap { m in rates.rate(for: m).map { (m, $0) } }
        guard !priced.isEmpty else { return }
        let expr = "cost_usd = input*? + cache_read*? + cache_write*? + output*?"
        let normal = try conn.prepare("UPDATE usage SET \(expr) WHERE model=? AND cost_usd=0 AND NOT (fast=1 AND provider='codex')")
        let priority = try conn.prepare("UPDATE usage SET \(expr) WHERE model=? AND cost_usd=0 AND fast=1 AND provider='codex'")
        defer { sqlite3_finalize(normal); sqlite3_finalize(priority) }
        try conn.exec("BEGIN")
        do {
            for (m, r) in priced {
                for (stmt, v) in [(normal, [r.input, r.cacheRead, r.cacheWrite, r.output]),
                                  (priority, [r.inputP, r.cacheReadP, r.cacheWriteP, r.outputP])] {
                    for (i, x) in v.enumerated() { sqlite3_bind_double(stmt, Int32(i + 1), x) }
                    bindText(stmt, 5, m)
                    try conn.run(stmt)
                }
            }
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

    /// Changed `*.jsonl` files below `root` (hidden directories skipped, like a shell glob).
    private static func jobs(in root: String, kind: Job.Kind, known: [String: (Int64, Double)]) -> [Job] {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [Job] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let (size, mtime) = fileStat(url.path), known[url.path].map({ $0 != (size, mtime) }) ?? true else { continue }
            out.append(Job(path: url.path, size: size, mtime: mtime, kind: kind))
        }
        return out
    }

    private static func t3Caches(in dir: String, known: [String: (Int64, Double)]) -> [Job] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("usage-scan-cache") && $0.hasSuffix(".json") }
            .compactMap { n -> Job? in
                let p = dir + "/" + n
                guard let (size, mtime) = fileStat(p), known[p].map({ $0 != (size, mtime) }) ?? true else { return nil }
                return Job(path: p, size: size, mtime: mtime, kind: .claude)
            }
            .sorted { $0.mtime < $1.mtime }
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
        sqlite3_bind_int64(s, 9, r.input); sqlite3_bind_int64(s, 10, r.cacheRead)
        sqlite3_bind_int64(s, 11, r.cacheWrite); sqlite3_bind_int64(s, 12, r.output)
        sqlite3_bind_int64(s, 13, r.reasoning); sqlite3_bind_int64(s, 14, r.fast ? 1 : 0)
        sqlite3_bind_double(s, 15, r.cost); bindText(s, 16, r.origin); bindText(s, 17, r.source)
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
