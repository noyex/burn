import Foundation

/// Prints live limits and usage summaries for verification (`Burn --dump`). Never prints tokens.
func runDebugDump() async {
    let fetchers: [any LimitsFetcher] = [ClaudeLimitsFetcher(), CodexLimitsFetcher(), CursorLimitsFetcher()]
    for f in fetchers {
        print("== \(f.provider.name) connected=\(f.isConnected())")
        do {
            let l = try await f.fetch()
            print("  plan: \(l.plan ?? "?")")
            for w in l.windows {
                let reset = w.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "-"
                print("  \(w.id) [\(w.label)] \(String(format: "%.1f", w.percent))% resets \(reset)")
            }
        } catch {
            print("  error: \(error.localizedDescription) (\(error))")
        }
    }

    printUsageSummaries()
}

/// Runs the usage importer and prints timing, totals and per-period summaries (`Burn --import`).
func runDebugImport() async {
    let tick = ProgressTicker()
    let t0 = Date()
    do {
        let r = try await UsageImporter.shared.run { p in tick.report(p) }
        let secs = Date().timeIntervalSince(t0)
        print("import: \(r.parsedFiles) files parsed, \(r.newRows) new rows, \(r.totalRows) total in \(String(format: "%.2f", secs)) s -> \(UsageStore.dbPath)")
    } catch {
        print("import error: \(error.localizedDescription)")
    }
    printUsageSummaries()
}

private final class ProgressTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDecile = -1
    func report(_ p: ImportProgress) {
        guard p.total > 0 else { return }
        let decile = p.done * 10 / p.total
        lock.lock(); defer { lock.unlock() }
        guard decile != lastDecile else { return }
        lastDecile = decile
        print("  progress \(decile * 10)% (\(p.done)/\(p.total))")
    }
}

private func printUsageSummaries() {
    let db = UsageDatabase()
    for p in Period.allCases {
        let t0 = Date()
        do {
            let s = try db.summary(for: p)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("== \(p.title): $\(String(format: "%.2f", s.cost)) tokens=\(s.tokens) buckets=\(s.buckets.count) unit=\(s.unit) (\(ms) ms)")
            print("  byProvider: " + s.byProvider.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=$\(String(format: "%.2f", $0.value))" }.joined(separator: " "))
            if let a = s.buckets.first, let b = s.buckets.last {
                print("  first: \(a.start) $\(String(format: "%.2f", a.total))  last: \(b.start) $\(String(format: "%.2f", b.total))")
            }
        } catch {
            print("== \(p.title): error \(error.localizedDescription)")
        }
    }
}
