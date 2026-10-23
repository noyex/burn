import Foundation

// Ports of T3 Code's usage readers (`claudeUsageReader.ts`, `codexUsage.ts`, `usageScanCache.ts`).
// Per-record tokens, speed and reported cost must stay identical to T3's; `Burn --verify-t3` checks that.

enum Speed: String, Sendable {
    case standard, fast, ultrafast
    /// Index used by T3's scan cache.
    static let cacheOrder: [Speed] = [.standard, .fast, .ultrafast]
}

struct TokenTotals: Sendable, Equatable {
    var uncached: Int64 = 0, cached: Int64 = 0, cacheCreation: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0
    /// Reasoning is already inside output, so it is not part of the total.
    var total: Int64 { uncached + cached + cacheCreation + output }
}

/// One parsed usage record, before pricing. Same shape as T3's `UsageRecord`.
struct UsageRecord: Sendable {
    let provider: String
    let tsMs: Int64
    let model: String
    let rateModel: String?
    let sessionId: String
    let project: String?
    let totals: TokenTotals
    let reportedCost: Double?
    var speed: Speed
    let dedupeKey: String?
    /// Codex turn whose service tier is unknown (resolved later from T3's database).
    let tierTurn: String?
}

/// One usage record, ready to be written to the store.
struct UsageRow: Sendable {
    let id, provider: String
    let model: String
    let tsMs: Int64
    let ts, day: String
    let session, project: String?
    let totals: TokenTotals
    let speed: Speed
    let reportedCost: Double?
    let rateModel, tierTurn: String?
    let cost: Double
    let origin, source: String

    init(record r: UsageRecord, id: String, project: String?, origin: String, source: String, rates: ModelRates) {
        self.id = id; provider = r.provider; model = r.model; tsMs = r.tsMs
        session = r.sessionId.isEmpty ? nil : r.sessionId
        self.project = r.project ?? project
        totals = r.totals; speed = r.speed; reportedCost = r.reportedCost
        rateModel = r.rateModel; tierTurn = r.tierTurn
        self.origin = origin; self.source = source
        cost = rates.cost(model: r.model, rateModel: r.rateModel, speed: r.speed, uncached: r.totals.uncached,
                          cached: r.totals.cached, cacheCreation: r.totals.cacheCreation, output: r.totals.output,
                          reported: r.reportedCost)
        // Local time, like the reference importer.
        var t = time_t(tsMs / 1000)
        var tmv = tm()
        localtime_r(&t, &tmv)
        var buf = [CChar](repeating: 0, count: 32)
        let n = strftime(&buf, 32, "%Y-%m-%dT%H:%M:%S", &tmv)
        let s = String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        ts = s
        day = String(s.prefix(10))
    }
}

/// ISO-8601 (`2026-01-02T03:04:05.678Z` or with an offset) to epoch ms, like `Date.parse` (extra fraction digits truncate).
func isoToMs(_ str: String) -> Int64? {
    let b = Array(str.utf8)
    guard b.count >= 19 else { return nil }
    func n(_ r: Range<Int>) -> Int? {
        var v = 0
        for i in r { guard b[i] >= 48, b[i] <= 57 else { return nil }; v = v * 10 + Int(b[i] - 48) }
        return v
    }
    guard let y = n(0..<4), let mo = n(5..<7), let d = n(8..<10), let h = n(11..<13),
          let mi = n(14..<16), let s = n(17..<19) else { return nil }
    var i = 19
    var millis = 0
    if i < b.count, b[i] == 46 {
        i += 1
        var digits = 0
        while i < b.count, b[i] >= 48, b[i] <= 57 {
            if digits < 3 { millis = millis * 10 + Int(b[i] - 48); digits += 1 }
            i += 1
        }
        while digits < 3 { millis *= 10; digits += 1 }
    }
    var offset = 0
    if i < b.count, b[i] == 43 || b[i] == 45, let oh = n((i + 1)..<min(i + 3, b.count)) {
        let om = i + 6 <= b.count ? (n((i + 4)..<(i + 6)) ?? 0) : 0
        offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
    }
    var t = tm()
    (t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec) = (Int32(y - 1900), Int32(mo - 1), Int32(d), Int32(h), Int32(mi), Int32(s))
    let secs = Int64(timegm(&t)) - Int64(offset)
    return secs * 1000 + Int64(millis)
}

// MARK: - JSON helpers

/// JSON number (not a boolean), finite.
private func num(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite ? d : nil
}
private func int(_ v: Any?) -> Int64 { num(v).map { Int64($0) } ?? 0 }
private func str(_ v: Any?) -> String? { v as? String }
private func timestamp(_ v: Any?) -> Int64? { (v as? String).flatMap(isoToMs) }

/// Calls `body` with the JSON object of every line that contains at least one needle.
private func scanLines(_ data: Data, needles: [String], _ body: ([String: Any]) -> Void) {
    let pats = needles.map { Array($0.utf8) }
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        let n = raw.count
        var pos = 0
        while pos < n {
            let p = base + pos
            let end = memchr(p, 10, n - pos).map { base.distance(to: UnsafeRawPointer($0)) } ?? n
            let len = end - pos
            if len > 2, pats.contains(where: { memmem(p, len, $0, $0.count) != nil }) {
                let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: len, deallocator: .none)
                if let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { body(d) }
            }
            pos = end + 1
        }
    }
}

private func mapped(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
}

// MARK: - Claude

/// T3's `tokenCount`: positive finite numbers, truncated.
private func tokenCount(_ v: Any?) -> Int64 {
    guard let d = num(v), d > 0 else { return 0 }
    return Int64(d.rounded(.towardZero))
}

private func claudeRecord(_ d: [String: Any]) -> UsageRecord? {
    guard d["type"] as? String == "assistant", let msg = d["message"] as? [String: Any],
          let u = msg["usage"] as? [String: Any], let ms = timestamp(d["timestamp"]),
          let model = str(msg["model"]), !model.isEmpty, model != "<synthetic>" else { return nil }
    let mid = str(msg["id"]), rid = str(d["requestId"])
    let key = mid == nil && rid == nil ? nil : "\(mid ?? ""):\(rid ?? "")"
    return UsageRecord(
        provider: "claude", tsMs: ms, model: model, rateModel: nil, sessionId: str(d["sessionId"]) ?? "",
        project: str(d["cwd"]),
        totals: TokenTotals(uncached: tokenCount(u["input_tokens"]), cached: tokenCount(u["cache_read_input_tokens"]),
                            cacheCreation: tokenCount(u["cache_creation_input_tokens"]),
                            output: tokenCount(u["output_tokens"]), reasoning: 0),
        reportedCost: num(d["costUSD"]), speed: str(u["speed"]) == "fast" ? .fast : .standard,
        dedupeKey: key, tierTurn: nil)
}

/// Records of one Claude transcript, in file order, repeats of a `dedupeKey` dropped (first kept).
func parseClaudeRecords(path: String) throws -> [UsageRecord] {
    var out: [UsageRecord] = []
    scanLines(try mapped(path), needles: ["\"usage\""]) { d in
        if let r = claudeRecord(d) { out.append(r) }
    }
    return dedupeWithinFile(out)
}

/// `dedupeWithinFile`: one `seen` set over the whole file, first occurrence wins.
func dedupeWithinFile(_ records: [UsageRecord]) -> [UsageRecord] {
    var seen = Set<String>()
    return records.filter { r in
        guard let k = r.dedupeKey else { return true }
        return seen.insert(k).inserted
    }
}

// MARK: - Codex

private struct CodexUsage: Equatable {
    var input, cached, cacheWrite, output, reasoning, total: Int64

    var isValid: Bool {
        cached + cacheWrite <= input && reasoning <= output && total >= input + output
    }

    /// `readCodexTokenUsage`.
    static func read(_ value: Any?) -> CodexUsage? {
        guard let raw = value as? [String: Any] else { return nil }
        func field(_ k: String) -> Int64?? {
            guard let v = raw[k] else { return .some(nil) }       // missing -> default
            guard let d = num(v), d >= 0, d == d.rounded() else { return nil }  // present but invalid
            return .some(Int64(d))
        }
        guard let i = num(raw["input_tokens"]), let o = num(raw["output_tokens"]),
              i >= 0, o >= 0, i == i.rounded(), o == o.rounded(),
              let c = field("cached_input_tokens"), let w = field("cache_write_input_tokens"),
              let r = field("reasoning_output_tokens"), let t = field("total_tokens") else { return nil }
        let u = CodexUsage(input: Int64(i), cached: c ?? 0, cacheWrite: w ?? 0, output: Int64(o), reasoning: r ?? 0,
                           total: t ?? Int64(i) + Int64(o))
        return u.isValid ? u : nil
    }

    /// `advanceCodexUsage`.
    static func advance(_ prev: CodexUsage?, _ last: CodexUsage) -> CodexUsage? {
        let u = CodexUsage(input: (prev?.input ?? 0) + last.input, cached: (prev?.cached ?? 0) + last.cached,
                           cacheWrite: (prev?.cacheWrite ?? 0) + last.cacheWrite, output: (prev?.output ?? 0) + last.output,
                           reasoning: (prev?.reasoning ?? 0) + last.reasoning, total: (prev?.total ?? 0) + last.total)
        return u.isValid ? u : nil
    }
}

private struct CodexScanState {
    var model = "", speed = Speed.standard, sessionId = "", modelProvider = "", turnId = ""
    var project: String?
    var lastSignature: CodexUsage?
    var lastCumulative: CodexUsage?
    var sawSessionMeta = false, sawThreadSettings = false, suppressingForkCopies = false
    var forkCopyAnchorMs: Int64 = 0
}

private let forkCopyMaxGapMs: Int64 = 1000

private func isForkedSessionMeta(_ p: [String: Any]) -> Bool {
    if p["forked_from_id"] is String { return true }
    return ((p["source"] as? [String: Any])?["subagent"] as? [String: Any])
        .flatMap { $0["thread_spawn"] as? [String: Any] }?["parent_thread_id"] is String
}

private func codexSpeed(_ tier: Any?) -> Speed {
    switch tier as? String {
    case "priority", "fast": .fast
    case "ultrafast": .ultrafast
    default: .standard
    }
}

/// `parseCodexRecord`: one line of a Codex rollout, updating `state`.
private func codexRecord(_ rec: [String: Any], _ s: inout CodexScanState) -> UsageRecord? {
    guard let payload = rec["payload"] as? [String: Any] else { return nil }
    let payloadType = payload["type"] as? String
    let type = rec["type"] as? String
    if type == "session_meta" {
        if s.sawSessionMeta { return nil }
        s.sawSessionMeta = true
        let idv: Any? = (payload["id"] == nil || payload["id"] is NSNull) ? payload["session_id"] : payload["id"]
        if let id = idv as? String { s.sessionId = id }
        s.project = str(payload["cwd"])
        if let mp = payload["model_provider"] as? String { s.modelProvider = mp }
        if let ms = timestamp(rec["timestamp"]), isForkedSessionMeta(payload) {
            s.suppressingForkCopies = true
            s.forkCopyAnchorMs = ms
        }
        return nil
    }
    if type == "turn_context" {
        if let m = payload["model"] as? String { s.model = m }
        if let t = payload["turn_id"] as? String, let m = payload["model"] as? String, !m.isEmpty { s.turnId = t } else { s.turnId = "" }
        return nil
    }
    if payloadType == "thread_settings_applied" {
        s.sawThreadSettings = true
        if let settings = payload["thread_settings"] as? [String: Any] { s.speed = codexSpeed(settings["service_tier"]) }
        return nil
    }
    guard payloadType == "token_count", let info = payload["info"] as? [String: Any],
          let ts = timestamp(rec["timestamp"]), !s.model.isEmpty else { return nil }
    let last = CodexUsage.read(info["last_token_usage"])
    let rawCum = info["total_token_usage"]
    let hasCum = rawCum != nil && !(rawCum is NSNull)
    let cum = hasCum ? CodexUsage.read(rawCum) : nil

    if s.suppressingForkCopies {
        if ts - s.forkCopyAnchorMs < forkCopyMaxGapMs {
            s.forkCopyAnchorMs = ts
            if let cum { s.lastCumulative = cum }
            else if !hasCum, let last, last != s.lastSignature { s.lastCumulative = CodexUsage.advance(s.lastCumulative, last) }
            s.lastSignature = last
            return nil
        }
        s.suppressingForkCopies = false
        s.lastSignature = nil
    }
    let previous = s.lastCumulative
    if let cum { s.lastCumulative = cum }
    guard let last, !(hasCum && cum == nil) else { return nil }
    if let cum, last.input + last.output == 0, cum.input + cum.output == 0,
       num(info["model_context_window"]) == Double(cum.total) {
        s.lastSignature = nil
        return nil
    }
    if let cum, let previous, cum == previous { return nil }
    if last.total != last.input + last.output { return nil }
    if let cum {
        let p = previous
        guard cum.input - (p?.input ?? 0) == last.input, cum.cached - (p?.cached ?? 0) == last.cached,
              cum.cacheWrite - (p?.cacheWrite ?? 0) == last.cacheWrite, cum.output - (p?.output ?? 0) == last.output,
              cum.reasoning - (p?.reasoning ?? 0) == last.reasoning, cum.total - (p?.total ?? 0) == last.total
        else { return nil }
    } else {
        if last == s.lastSignature { return nil }
        guard let adv = CodexUsage.advance(previous, last) else { return nil }
        s.lastCumulative = adv
    }
    s.lastSignature = last
    let totals = TokenTotals(uncached: last.input - last.cached - last.cacheWrite, cached: last.cached,
                             cacheCreation: last.cacheWrite, output: last.output, reasoning: last.reasoning)
    if totals.total == 0 { return nil }
    let unresolved = !s.sawThreadSettings && s.modelProvider == "openai" && !s.sessionId.isEmpty && !s.turnId.isEmpty
    return UsageRecord(provider: "codex", tsMs: ts, model: s.model, rateModel: nil, sessionId: s.sessionId,
                       project: s.project, totals: totals, reportedCost: nil, speed: s.speed, dedupeKey: nil,
                       tierTurn: unresolved ? s.turnId : nil)
}

func parseCodexRecords(path: String) throws -> [UsageRecord] {
    var state = CodexScanState()
    var out: [UsageRecord] = []
    scanLines(try mapped(path), needles: ["\"token_count\"", "\"turn_context\"", "\"thread_settings_applied\"", "\"session_meta\""]) { d in
        if let r = codexRecord(d, &state) { out.append(r) }
    }
    return out
}

// MARK: - Row identity

/// Store ids that reproduce T3's dedupe: Claude by `messageId:requestId`; Codex sessions shared between files by
/// (session, timestamp, model, totals) plus the occurrence within the file. Records T3 never dedupes get a unique id.
func makeRows(_ records: [UsageRecord], path: String, origin: String, project: String?, rates: ModelRates) -> [UsageRow] {
    var occurrences: [String: Int] = [:]
    var rows: [UsageRow] = []
    rows.reserveCapacity(records.count)
    for (i, r) in records.enumerated() {
        let id: String
        if r.provider == "codex" {
            if r.sessionId.isEmpty { id = "codex:\(path)#\(i)" }
            else {
                let t = r.totals
                let key = "codex:\(r.sessionId):\(r.tsMs):\(r.model):\(t.uncached):\(t.cached):\(t.cacheCreation):\(t.output):\(t.reasoning)"
                let n = (occurrences[key] ?? 0) + 1
                occurrences[key] = n
                id = "\(key)#\(n)"
            }
        } else {
            id = r.dedupeKey ?? "claude:\(path)#\(i)"
        }
        rows.append(UsageRow(record: r, id: id, project: project, origin: origin, source: path, rates: rates))
    }
    return rows
}

// MARK: - T3 scan cache

/// One transcript's records as T3 saved them.
struct T3CacheFile: Sendable {
    let path: String
    let provider: String
    let size: Int64
    let records: [UsageRecord]
}

/// Cache format version from a file name (`usage-scan-cache-v7.json` -> 7, unversioned -> 0).
func t3CacheVersion(_ name: String) -> Int {
    guard let r = name.range(of: "-v"), let end = name.range(of: ".json") else { return 0 }
    return Int(name[r.upperBound..<end.lowerBound]) ?? 0
}

/// Decodes T3's usage-scan-cache*.json (`decodeScanCache`). Entries that fail validation are skipped, like T3 does.
func parseT3Cache(path: String) throws -> [T3CacheFile] {
    guard let d = try JSONSerialization.jsonObject(with: mapped(path)) as? [String: Any],
          let version = num(d["version"]), version >= 4, version <= 7,
          let models = d["models"] as? [String], let sessions = d["sessions"] as? [String],
          let files = d["files"] as? [String: Any] else { return [] }

    func decode(_ rows: [Any], _ provider: String, _ src: String) -> [UsageRecord]? {
        var out: [UsageRecord] = []
        for case let r as [Any] in rows {
            // [ts_ms, model, session, uncached, cached, cacheCreation, output, reasoning, dedupeKey, reportedCost, speed, rateModel, tierTurn?]
            guard r.count >= 11, let ts = num(r[0]), let mi = num(r[1]).map(Int.init), mi >= 0, mi < models.count,
                  let u = num(r[3]), let c = num(r[4]), let w = num(r[5]), let o = num(r[6]), let re = num(r[7]),
                  let si = num(r[10]).map(Int.init), si >= 0, si < Speed.cacheOrder.count else { return nil }
            var rateModel: String?
            if r.count > 11, !(r[11] is NSNull), r[11] as? NSNumber != nil {
                guard let ri = num(r[11]).map(Int.init), ri >= 0, ri < models.count else { return nil }
                rateModel = models[ri]
            }
            var tier: String?
            if version >= 7, r.count > 12 {
                guard let t = r[12] as? String else { return nil }
                tier = t
            }
            let model = models[mi]
            if provider == "claude" && model == "<synthetic>" { continue }
            let sess = num(r[2]).map(Int.init).flatMap { $0 >= 0 && $0 < sessions.count ? sessions[$0] : nil } ?? ""
            out.append(UsageRecord(
                provider: provider, tsMs: Int64(ts), model: model, rateModel: rateModel, sessionId: sess,
                project: provider == "claude" ? URL(fileURLWithPath: src).deletingLastPathComponent().lastPathComponent : nil,
                totals: TokenTotals(uncached: Int64(u), cached: Int64(c), cacheCreation: Int64(w), output: Int64(o), reasoning: Int64(re)),
                reportedCost: num(r[9]), speed: Speed.cacheOrder[si],
                dedupeKey: r[8] as? String, tierTurn: tier))
        }
        return out
    }

    var out: [T3CacheFile] = []
    for (src, e) in files {
        guard let entry = e as? [String: Any], let provider = str(entry["p"]), provider == "claude" || provider == "codex",
              num(entry["s"]) != nil, num(entry["m"]) != nil,
              let r = entry["r"] as? [Any], let t = entry["t"] as? [Any],
              let rec = decode(r, provider, src), let tail = decode(t, provider, src) else { continue }
        // `records` and `tailRecords` are deduped with one shared set.
        let merged = provider == "claude" ? dedupeWithinFile(rec + tail) : rec + tail
        out.append(T3CacheFile(path: src, provider: provider, size: Int64(num(entry["s"]) ?? -1), records: merged))
    }
    return out.sorted { $0.path < $1.path }
}
