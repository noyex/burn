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

/// Compares Burn's parsing and pricing with T3's own scan cache (`Burn --verify-t3`).
func runVerifyT3() {
    let dir = NSHomeDirectory() + "/.t3/userdata"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasPrefix("usage-scan-cache") && $0.hasSuffix(".json") }
        .sorted { t3CacheVersion($0) > t3CacheVersion($1) }
    guard let name = names.first, let files = try? parseT3Cache(path: dir + "/" + name) else {
        print("no readable T3 scan cache in \(dir)"); return
    }
    guard let rates = ModelRates.loadT3Only() else { print("no T3 rate table"); return }
    print("T3 cache \(name): \(files.count) claude/codex transcripts, rates hash \(rates.hash.prefix(12)), \(rates.table.count) rate keys")

    struct Tally {
        var files = 0, exact = 0, prefix = 0, missing = 0, t3Records = 0, compared = 0, countMismatch = 0
        var field: [String: Int] = [:]
        var costT3 = 0.0, costBurn = 0.0, tokensT3: Int64 = 0, tokensBurn: Int64 = 0
        var examples: [String] = []
    }
    var tally: [String: Tally] = [:]
    for f in files {
        var t = tally[f.provider] ?? Tally()
        defer { tally[f.provider] = t }
        t.files += 1
        var st = stat()
        guard stat(f.path, &st) == 0 else { t.missing += 1; continue }
        guard let burn = try? (f.provider == "claude" ? parseClaudeRecords(path: f.path) : parseCodexRecords(path: f.path)) else {
            t.field["unreadable", default: 0] += 1; continue
        }
        let isExact = Int64(st.st_size) == f.size
        if isExact { t.exact += 1 } else { t.prefix += 1 }
        t.t3Records += f.records.count
        if isExact, burn.count != f.records.count {
            t.countMismatch += 1
            if t.examples.count < 8 { t.examples.append("count \(f.path): T3 \(f.records.count) Burn \(burn.count)") }
        } else if !isExact, burn.count < f.records.count {
            t.countMismatch += 1
            if t.examples.count < 8 { t.examples.append("count(grown) \(f.path): T3 \(f.records.count) Burn \(burn.count)") }
        }
        for (i, a) in f.records.enumerated() where i < burn.count {
            let b = burn[i]
            t.compared += 1
            var bad: [String] = []
            if a.tsMs != b.tsMs { bad.append("ts") }
            if a.model != b.model { bad.append("model") }
            if a.sessionId != b.sessionId { bad.append("session") }
            if a.totals != b.totals { bad.append("tokens") }
            if a.speed != b.speed { bad.append("speed") }
            if a.reportedCost != b.reportedCost { bad.append("reportedCost") }
            if a.dedupeKey != b.dedupeKey { bad.append("dedupeKey") }
            for k in bad { t.field[k, default: 0] += 1 }
            if !bad.isEmpty, t.examples.count < 8 {
                t.examples.append("\(bad.joined(separator: ",")) \(f.path)#\(i): T3 \(a.totals) \(a.speed) | Burn \(b.totals) \(b.speed)")
            }
            func price(_ r: UsageRecord) -> Double {
                rates.cost(model: r.model, rateModel: r.rateModel, speed: r.speed, uncached: r.totals.uncached, cached: r.totals.cached,
                           cacheCreation: r.totals.cacheCreation, output: r.totals.output, reported: r.reportedCost)
            }
            t.costT3 += price(a); t.costBurn += price(b)
            t.tokensT3 += a.totals.total; t.tokensBurn += b.totals.total
        }
    }
    for (p, t) in tally.sorted(by: { $0.key < $1.key }) {
        print("== \(p): \(t.files) transcripts in T3 cache (\(t.exact) size-identical, \(t.prefix) grown since, \(t.missing) deleted from disk)")
        print("   records: T3 \(t.t3Records), compared \(t.compared), file count mismatches \(t.countMismatch)")
        print("   field mismatches: \(t.field.isEmpty ? "none" : t.field.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print("   tokens: T3 \(t.tokensT3) Burn \(t.tokensBurn)")
        print(String(format: "   cost (T3 rates): T3 records $%.6f, Burn records $%.6f, diff $%.6f", t.costT3, t.costBurn, t.costBurn - t.costT3))
        for e in t.examples { print("   ! \(e)") }
    }
}
