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
