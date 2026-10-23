import Foundation
import SQLite3

enum UsageDatabaseError: LocalizedError {
    case open(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): "Can't open usage database: \(m)"
        case .query(let m): "Usage query failed: \(m)"
        }
    }
}

final class UsageDatabase: Sendable {
    let path: String

    init(path: String? = nil) {
        self.path = path
            ?? ProcessInfo.processInfo.environment["T3_USAGE_DB"]
            ?? NSHomeDirectory() + "/.t3-usage/usage.sqlite"
    }

    /// Synchronous; call off the main actor.
    func summary(for period: Period, now: Date = .now) throws -> UsageSummary {
        var cal = Calendar.current
        cal.firstWeekday = 2 // weeks start Monday
        cal.minimumDaysInFirstWeek = 4

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw UsageDatabaseError.open(m)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let todayStart = cal.startOfDay(for: now)
        let unit: BucketUnit
        let component: Calendar.Component
        var start: Date
        let count: Int?
        switch period {
        case .today:
            (unit, component, start, count) = (.hour, .hour, todayStart, 24)
        case .week:
            (unit, component, start, count) = (.day, .day, cal.date(byAdding: .day, value: -6, to: todayStart)!, 7)
        case .month:
            (unit, component, start, count) = (.day, .day, cal.date(byAdding: .day, value: -29, to: todayStart)!, 30)
        case .all:
            var first: Int64?
            try query(db, "SELECT MIN(ts_ms) FROM usage") { stmt in
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL { first = sqlite3_column_int64(stmt, 0) }
            }
            let firstDate = first.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now
            start = cal.dateInterval(of: .weekOfYear, for: min(firstDate, now))?.start ?? todayStart
            (unit, component, count) = (.week, .weekOfYear, nil)
        }

        // Bucket start dates, contiguous.
        var starts: [Date] = []
        var cursor = start
        let lastNeeded = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        while count.map({ starts.count < $0 }) ?? (cursor <= lastNeeded) {
            starts.append(cursor)
            cursor = cal.date(byAdding: component, value: 1, to: cursor)!
        }
        let end = cursor
        let startsMs = starts.map { Int64($0.timeIntervalSince1970 * 1000) }

        var costs = [[ProviderID: Double]](repeating: [:], count: starts.count)
        var byProvider: [ProviderID: Double] = [:]
        var tokens: Int64 = 0
        var total = 0.0
        let sql = "SELECT ts_ms, provider, cost_usd, input + cache_read + cache_write + output FROM usage WHERE ts_ms >= ? AND ts_ms < ?"
        try query(db, sql, binds: [startsMs[0], Int64(end.timeIntervalSince1970 * 1000)]) { stmt in
            guard let c = sqlite3_column_text(stmt, 1), let p = ProviderID(rawValue: String(cString: c)),
                  p == .claude || p == .codex else { return }
            let ts = sqlite3_column_int64(stmt, 0)
            let cost = sqlite3_column_double(stmt, 2)
            // Last bucket whose start <= ts.
            var lo = 0, hi = startsMs.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if startsMs[mid] <= ts { lo = mid } else { hi = mid - 1 }
            }
            costs[lo][p, default: 0] += cost
            byProvider[p, default: 0] += cost
            total += cost
            tokens += sqlite3_column_int64(stmt, 3)
        }

        let buckets = zip(starts, costs).map { UsageBucket(start: $0, cost: $1) }
        return UsageSummary(period: period, cost: total, tokens: tokens, byProvider: byProvider, buckets: buckets, unit: unit)
    }

    private func query(_ db: OpaquePointer?, _ sql: String, binds: [Int64] = [], row: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageDatabaseError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in binds.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), v) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt) }
            else if rc == SQLITE_DONE { return }
            else { throw UsageDatabaseError.query(String(cString: sqlite3_errmsg(db))) }
        }
    }
}
