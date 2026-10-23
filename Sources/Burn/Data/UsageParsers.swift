import Foundation

/// One usage record, ready to be written to the store.
struct UsageRow: Sendable {
    let id, provider: String
    let model: String?
    let tsMs: Int64
    let ts, day: String
    let session, project: String?
    let input, cacheRead, cacheWrite, output, reasoning: Int64
    let fast: Bool
    let cost: Double
    let origin, source: String

    init(id: String, provider: String, model: String?, tsMs: Int64, session: String?, project: String?,
         input: Int64, cacheRead: Int64, cacheWrite: Int64, output: Int64, reasoning: Int64, fast: Bool,
         origin: String, source: String, rates: ModelRates) {
        self.id = id; self.provider = provider; self.model = model; self.tsMs = tsMs
        self.session = session; self.project = project
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.output = output; self.reasoning = reasoning; self.fast = fast
        self.origin = origin; self.source = source
        cost = rates.cost(provider: provider, model: model, input: input, cacheRead: cacheRead,
                          cacheWrite: cacheWrite, output: output, fast: fast)
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

/// ISO-8601 (`2026-01-02T03:04:05.678Z` or with an offset) to epoch ms; mirrors Python's float math.
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
    var micros = 0
    if i < b.count, b[i] == 46 {
        i += 1
        var digits = 0
        while i < b.count, b[i] >= 48, b[i] <= 57 {
            if digits < 6 { micros = micros * 10 + Int(b[i] - 48); digits += 1 }
            i += 1
        }
        while digits < 6 { micros *= 10; digits += 1 }
    }
    var offset = 0
    if i < b.count, b[i] == 43 || b[i] == 45, let oh = n((i + 1)..<min(i + 3, b.count)) {
        let om = i + 6 <= b.count ? (n((i + 4)..<(i + 6)) ?? 0) : 0
        offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
    }
    var t = tm()
    (t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec) = (Int32(y - 1900), Int32(mo - 1), Int32(d), Int32(h), Int32(mi), Int32(s))
    let secs = Int64(timegm(&t)) - Int64(offset)
    let ts = Double(secs * 1_000_000 + Int64(micros)) / 1_000_000
    return Int64(ts * 1000)
}

private func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
private func str(_ v: Any?) -> String? { v as? String }

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

func parseClaude(path: String, rates: ModelRates) throws -> [UsageRow] {
    var rows: [String: UsageRow] = [:]
    scanLines(try mapped(path), needles: ["\"usage\""]) { d in
        guard d["type"] as? String == "assistant", let msg = d["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any], !u.isEmpty,
              let mid = str(msg["id"]), !mid.isEmpty, let tss = str(d["timestamp"]), !tss.isEmpty,
              let model = str(msg["model"]), !model.isEmpty, model != "<synthetic>",
              let ms = isoToMs(tss) else { return }
        let key = "\(mid):\(str(d["requestId"]) ?? "")"
        // Streaming writes one line per content block; the last one carries final usage.
        rows[key] = UsageRow(
            id: key, provider: "claude", model: model, tsMs: ms, session: str(d["sessionId"]), project: str(d["cwd"]),
            input: int(u["input_tokens"]), cacheRead: int(u["cache_read_input_tokens"]),
            cacheWrite: int(u["cache_creation_input_tokens"]), output: int(u["output_tokens"]),
            reasoning: int((u["output_tokens_details"] as? [String: Any])?["thinking_tokens"]),
            fast: str(u["speed"]) == "fast", origin: "log", source: path, rates: rates)
    }
    return Array(rows.values)
}

func codexKey(_ ts: Int64, _ input: Int64, _ cached: Int64, _ out: Int64) -> String {
    // Forked sessions replay the parent's token events, so the event itself is the stable identity.
    "codex:\(ts):\(input):\(cached):\(out)"
}

func parseCodex(path: String, rates: ModelRates) throws -> [UsageRow] {
    var rows: [UsageRow] = []
    var thread: String?, project: String?, model: String?
    var fast = false
    var lastTotal: NSDictionary?
    var forkMs: Int64?
    scanLines(try mapped(path), needles: ["token_count", "session_meta", "turn_context", "thread_settings_applied"]) { d in
        let p = d["payload"] as? [String: Any] ?? [:]
        let pt = p["type"] as? String
        switch d["type"] as? String {
        case "session_meta":
            if thread == nil {
                thread = str(p["id"]); project = str(p["cwd"])
                if let f = str(p["forked_from_id"]), !f.isEmpty, let t = str(d["timestamp"]), !t.isEmpty { forkMs = isoToMs(t) }
            }
        case "turn_context":
            if let m = str(p["model"]), !m.isEmpty { model = m }
        case "event_msg" where pt == "thread_settings_applied":
            let s = p["thread_settings"] as? [String: Any] ?? [:]
            if let m = str(s["model"]), !m.isEmpty { model = m }
            if s["service_tier"] != nil { fast = ["priority", "fast"].contains(str(s["service_tier"]) ?? "") }
        case "event_msg" where pt == "token_count":
            let info = p["info"] as? [String: Any] ?? [:]
            let u = info["last_token_usage"] as? NSDictionary
            let total = info["total_token_usage"] as? NSDictionary
            guard let u = u as? [String: Any], !u.isEmpty, let tss = str(d["timestamp"]), !tss.isEmpty,
                  total != lastTotal, let ms = isoToMs(tss) else { return }
            lastTotal = total
            if let f = forkMs, ms <= f + 1000 { return }
            let cached = int(u["cached_input_tokens"])
            let inp = max(int(u["input_tokens"]) - cached, 0)
            let out = int(u["output_tokens"])
            rows.append(UsageRow(
                id: codexKey(ms, inp, cached, out), provider: "codex", model: model, tsMs: ms, session: thread,
                project: project, input: inp, cacheRead: cached, cacheWrite: int(u["cache_write_input_tokens"]),
                output: out, reasoning: int(u["reasoning_output_tokens"]), fast: fast, origin: "log",
                source: path, rates: rates))
        default: break
        }
    }
    return rows
}

/// T3's usage-scan-cache*.json: still holds records for logs that were deleted since.
func parseT3Cache(path: String, rates: ModelRates) throws -> [UsageRow] {
    guard let d = try JSONSerialization.jsonObject(with: mapped(path)) as? [String: Any] else { return [] }
    let models = d["models"] as? [Any] ?? [], sessions = d["sessions"] as? [Any] ?? []
    var rows: [UsageRow] = []
    for (src, e) in d["files"] as? [String: Any] ?? [:] {
        guard let entry = e as? [String: Any], let provider = str(entry["p"]), provider == "claude" || provider == "codex"
        else { continue }
        let project = provider == "claude" ? URL(fileURLWithPath: src).deletingLastPathComponent().lastPathComponent : nil
        for case let r as [Any] in entry["r"] as? [Any] ?? [] where r.count >= 9 {
            // [ts_ms, model_idx, session_idx, input, cache_read, cache_write, output, reasoning, id, _, fast, _, thread]
            let ts = int(r[0])
            let mi = (r[1] as? NSNumber)?.intValue, si = (r[2] as? NSNumber)?.intValue
            let model = mi.flatMap { $0 >= 0 && $0 < models.count ? models[$0] as? String : nil }
            if model == "<synthetic>" { continue }
            let sess = si.flatMap { $0 >= 0 && $0 < sessions.count ? sessions[$0] as? String : nil }
            let thread = r.count > 12 ? str(r[12]).flatMap { $0.isEmpty ? nil : $0 } ?? sess : sess
            let (inp, cr, cw, out) = (int(r[3]), int(r[4]), int(r[5]), int(r[6]))
            let key = str(r[8]).flatMap { $0.isEmpty ? nil : $0 } ?? codexKey(ts, inp, cr, out)
            rows.append(UsageRow(
                id: key, provider: provider, model: model, tsMs: ts, session: provider == "claude" ? sess : thread,
                project: project, input: inp, cacheRead: cr, cacheWrite: cw, output: out, reasoning: int(r[7]),
                fast: r.count > 10 && int(r[10]) == 1, origin: "t3-cache", source: src, rates: rates))
        }
    }
    return rows
}
