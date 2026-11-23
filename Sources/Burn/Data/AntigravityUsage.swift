import Foundation
import SQLite3

// Port of T3 Code's `antigravityUsageReader.ts` and `AntigravityUsage.ts`.
// Reads protobuf token-usage blobs from Antigravity conversation SQLite databases
// (`gen_metadata`, `steps`, `trajectory_metadata_blob`) and deduplicates retries / mirrored rows.

enum AntigravityUsage {
    /// Known Antigravity internal numeric model ids (mirrors T3's `MODEL_IDS`).
    static let modelIds: [Int: String] = [
        246: "gemini-2.5-pro",
        312: "gemini-2.5-flash",
        313: "gemini-2.5-flash-thinking",
        329: "gemini-2.5-flash-thinking",
        330: "gemini-2.5-flash-lite",
        281: "claude-sonnet-4",
        282: "claude-sonnet-4",
        290: "claude-opus-4",
        291: "claude-opus-4",
        333: "claude-sonnet-4-5",
        334: "claude-sonnet-4-5",
        340: "claude-haiku-4-5",
        341: "claude-haiku-4-5",
        342: "gpt-oss-120b-medium",
        1026: "claude-opus-4-6",
        1035: "claude-sonnet-4-6",
        1016: "gemini-3.1-pro",
        1036: "gemini-3.1-pro",
        1037: "gemini-3.1-pro",
        1018: "gemini-3-flash-preview",
        1084: "gemini-3-flash-preview",
        1047: "gemini-3-flash-preview",
        1020: "gemini-3.5-flash-medium",
        1021: "gemini-3.1-flash-image",
        1050: "gemini-3.1-flash-lite",
        1071: "gemini-3.6-flash-high",
        1072: "gemini-3.6-flash-medium",
        1073: "gemini-3.6-flash-low",
        1132: "gemini-3.5-flash-high",
        1133: "gemini-3.5-flash-high",
        1187: "gemini-3.5-flash-extra-low",
        1196: "gemini-3.6-flash",
        1266: "gemini-3.6-flash",
        1298: "gemini-3.7-flash-high",
        1299: "gemini-3.7-flash-medium",
        1300: "gemini-3.7-flash-low",
        1301: "gemini-3.7-flash-tiered",
        1318: "gemini-3.8-flash-high",
        1319: "gemini-3.8-flash-medium",
        1320: "gemini-3.8-flash-low",
        1322: "gemini-3.8-flash-tiered",
        1402: "claude-opus-5-5",
        1417: "gemini-4-argon",
        1418: "gemini-4-argon",
        1419: "gemini-4-argon",
        1537: "gemini-pro-orchestrator-neon",
    ]

    /// Maps an Antigravity model slug to its LiteLLM pricing key (mirrors `antigravityRateModel`).
    static func rateModel(for model: String) -> String {
        if model.range(of: #"^gemini-3-flash-(?:agent(?:-[ab])?|[ab])$"#, options: .regularExpression) != nil {
            return "gemini-3.5-flash"
        }
        if model == "gemini-3.7-flash-safety-le" { return "gemini-3.7-flash" }
        if model == "gemini-pro-orchestrator-neon" { return "gemini-4-neon" }
        if model == "gemini-pro-orchestrator-g1-pro" { return "gemini-4-argon" }
        var base = model
        let suffixes = ["-extra-low", "-low", "-medium", "-high", "-tiered", "-control", "-thinking", "-agent", "-orchestrator"]
        var stripped = true
        while stripped {
            stripped = false
            for suffix in suffixes where base.hasSuffix(suffix) {
                base.removeLast(suffix.count)
                stripped = true
                break
            }
        }
        return base == "gemini-3-flash" ? "gemini-3-flash-preview" : base
    }

    static func normalizeModelName(_ name: String) -> String {
        guard !name.isEmpty else { return "" }
        var s = name.lowercased()
        if let r = s.range(of: #"\s*\(([^)]*)\)\s*$"#, options: .regularExpression) {
            let inner = s[r].trimmingCharacters(in: .whitespaces)
            let trimmed = inner.dropFirst().dropLast()
            s.replaceSubrange(r, with: "-\(trimmed)")
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        if s.hasPrefix("claude-") {
            if let regex = try? NSRegularExpression(pattern: #"^claude-(\d+(?:\.\d+)?)-(sonnet|opus|haiku)"#) {
                let ns = s as NSString
                let range = NSRange(location: 0, length: ns.length)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "claude-$2-$1")
            }
            s = s.replacingOccurrences(of: ".", with: "-")
        }
        return s
    }

    static func isConcreteModel(_ model: String) -> Bool {
        model.range(of: #"^(?:gemini-\d|claude-(?:sonnet|opus|haiku)-\d|gpt-)"#, options: .regularExpression) != nil
            && model.range(of: #"^gemini-3-flash-(?:agent(?:-[ab])?|[ab])$"#, options: .regularExpression) == nil
    }

    /// Conversation directories containing Antigravity `.db` files (mirrors `AntigravityUsage.ts`).
    static func conversationDirectories(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var roots: [String] = []
        if let configured = env["ANTIGRAVITY_DATA_DIR"]?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }),
           !configured.isEmpty {
            for r in configured {
                let expanded = r.hasPrefix("~/") ? home + "/" + r.dropFirst(2) : (r == "~" ? home : r)
                roots.append(URL(fileURLWithPath: expanded).standardizedFileURL.path)
            }
        } else {
            for name in ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup"] {
                roots.append(home + "/.gemini/" + name)
            }
            roots.append(home + "/.config/antigravity")
        }

        let t3Root = home + "/.t3/userdata/providers/antigravity"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: t3Root) {
            for name in names.sorted() {
                roots.append(t3Root + "/" + name + "/antigravity-acp")
            }
        }

        var seen = Set<String>()
        var dirs: [String] = []
        let fm = FileManager.default
        for root in roots {
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            let nested = resolvedRoot + "/conversations"
            let dir = fm.fileExists(atPath: nested) ? nested : resolvedRoot
            let canonical = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted {
                dirs.append(canonical)
            }
        }
        return dirs
    }

    // MARK: - Protobuf wire parser

    private enum WireValue {
        case varint(UInt64)
        case bytes(Data)
    }

    private typealias Fields = [Int: [WireValue]]

    private static func parseFields(_ data: Data) throws -> Fields {
        var result: Fields = [:]
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var offset = 0

            func readVarint() throws -> UInt64 {
                var value: UInt64 = 0
                var shift: UInt64 = 0
                while shift < 70 {
                    guard offset < count else { throw ProtoError.invalid }
                    let byte = base[offset]
                    offset += 1
                    if shift == 63 && byte > 1 { throw ProtoError.invalid }
                    value |= UInt64(byte & 0x7F) << shift
                    if byte < 0x80 { return value }
                    shift += 7
                }
                throw ProtoError.invalid
            }

            while offset < count {
                let tag = try readVarint()
                let fieldNum = Int(tag >> 3)
                let wire = Int(tag & 7)
                guard fieldNum > 0 else { throw ProtoError.invalid }
                switch wire {
                case 0:
                    let v = try readVarint()
                    result[fieldNum, default: []].append(.varint(v))
                case 1:
                    guard count - offset >= 8 else { throw ProtoError.invalid }
                    offset += 8
                case 5:
                    guard count - offset >= 4 else { throw ProtoError.invalid }
                    offset += 4
                case 2:
                    let len64 = try readVarint()
                    guard len64 <= UInt64(count - offset) else { throw ProtoError.invalid }
                    let len = Int(len64)
                    let slice = Data(bytes: base + offset, count: len)
                    offset += len
                    result[fieldNum, default: []].append(.bytes(slice))
                default:
                    throw ProtoError.invalid
                }
            }
        }
        return result
    }

    private enum ProtoError: Error { case invalid }

    private static func numberAt(_ f: Fields, _ key: Int) -> Int64 {
        guard let first = f[key]?.first, case .varint(let v) = first, v <= UInt64(Int64.max) else { return 0 }
        return Int64(v)
    }

    private static func bytesAt(_ f: Fields, _ key: Int) -> Data? {
        guard let first = f[key]?.first, case .bytes(let d) = first else { return nil }
        return d
    }

    private static func nested(_ f: Fields, _ key: Int) throws -> Fields {
        guard let d = bytesAt(f, key) else { return [:] }
        return try parseFields(d)
    }

    private static func textAt(_ f: Fields, _ key: Int) -> String {
        guard let d = bytesAt(f, key), let s = String(data: d, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func protoTimestampMs(_ f: Fields) -> Int64? {
        let secs = numberAt(f, 1)
        guard secs > 0 else { return nil }
        return secs * 1000 + numberAt(f, 2) / 1_000_000
    }

    // MARK: - Database decoding

    private struct MetadataEntry {
        let model: String
        let modelId: Int
        let timestampMs: Int64?
        let usages: [Fields]
    }

    private static func decodeMetadata(_ bytes: Data, step: Bool) throws -> MetadataEntry {
        let root = try parseFields(bytes)
        if !step && bytesAt(root, 1) == nil { throw ProtoError.invalid }
        let data = step ? root : try nested(root, 1)
        let model = step ? try nested(data, 24) : data
        let primaryUsage = try bytesAt(data, step ? 9 : 4).map(parseFields)
        var usages: [Fields] = primaryUsage.map { [$0] } ?? []
        for item in data[step ? 28 : 17] ?? [] {
            guard case .bytes(let retryData) = item else { throw ProtoError.invalid }
            let retry = try parseFields(retryData)
            if let ru = bytesAt(retry, 2) {
                usages.append(try parseFields(ru))
            }
        }
        let names = [textAt(model, step ? 12 : 19), textAt(model, step ? 8 : 21)].map(normalizeModelName)
        let chosen = names.first(where: isConcreteModel)
            ?? names.first(where: { !$0.isEmpty && $0.range(of: #"^model[_-]"#, options: .regularExpression) == nil })
            ?? ""
        let mid = Int(numberAt(model, step ? 1 : 3))
        let resolvedMid = mid != 0 ? mid : (primaryUsage.map { Int(numberAt($0, 1)) } ?? 0)
        let ts: Int64?
        if step {
            if let t = protoTimestampMs(try nested(data, 8)) {
                ts = t
            } else {
                ts = protoTimestampMs(try nested(data, 1))
            }
        } else {
            ts = protoTimestampMs(try nested(try nested(data, 9), 4))
        }
        return MetadataEntry(model: chosen, modelId: resolvedMid, timestampMs: ts, usages: usages)
    }

    private struct Candidate {
        var record: UsageRecord
        let modelId: Int
        var modelQuality: Int
        let keys: [String]
        var timestampQuality: Int
    }

    private struct Group {
        var candidate: Candidate
        var parent: Int
        var size: Int
        var owner: Int
    }

    private static func rememberModel(_ map: inout [Int: String?], id: Int, model: String) {
        if let existing = map[id] {
            if existing != model { map[id] = .some(nil) }
        } else {
            map[id] = .some(model)
        }
    }

    /// Parses one Antigravity conversation `.db` file into deduplicated `UsageRecord`s.
    static func parseDatabase(path: String) throws -> [UsageRecord] {
        var db: OpaquePointer?
        // Closed conversations are WAL databases without `-wal`/`-shm`; a plain read-only open can't
        // create the `-shm` and fails, so open those as immutable. Live ones keep their WAL readable.
        let live = FileManager.default.fileExists(atPath: path + "-wal")
        let target = live ? path : URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        guard sqlite3_open_v2(target, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ProtoError.invalid
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        var tables = Set<String>()
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { tables.insert(String(cString: c)) }
            }
        }
        guard tables.contains("gen_metadata") || tables.contains("steps") else { return [] }

        func readEntries(_ sql: String, step: Bool) throws -> [(idx: Int64, entry: MetadataEntry)] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [(Int64, MetadataEntry)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                    if step { continue }
                    throw ProtoError.invalid
                }
                let idx = sqlite3_column_int64(stmt, 0)
                guard let ptr = sqlite3_column_blob(stmt, 1) else {
                    if step { continue }
                    throw ProtoError.invalid
                }
                let len = Int(sqlite3_column_bytes(stmt, 1))
                let blob = Data(bytes: ptr, count: len)
                out.append((idx, try decodeMetadata(blob, step: step)))
            }
            return out.sorted { $0.0 < $1.0 }
        }

        let generations = tables.contains("gen_metadata")
            ? try readEntries("SELECT idx, data FROM gen_metadata ORDER BY rowid", step: false)
            : []
        var trajectoryTimestamp: Int64?
        if tables.contains("trajectory_metadata_blob") {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT data FROM trajectory_metadata_blob", -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW && trajectoryTimestamp == nil {
                    if let ptr = sqlite3_column_blob(stmt, 0) {
                        let len = Int(sqlite3_column_bytes(stmt, 0))
                        let root = try parseFields(Data(bytes: ptr, count: len))
                        trajectoryTimestamp = protoTimestampMs(try nested(root, 2))
                    }
                }
            }
        }
        let steps = tables.contains("steps")
            ? try readEntries("SELECT idx, metadata FROM steps ORDER BY rowid", step: true)
            : []

        var st = stat()
        let fallbackMs: Int64 = stat(path, &st) == 0
            ? Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
            : Int64(Date().timeIntervalSince1970 * 1000)
        let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

        var learnedModels: [Int: String?] = [:]
        for (_, entry) in generations + steps where entry.modelId > 0 && isConcreteModel(entry.model) {
            rememberModel(&learnedModels, id: entry.modelId, model: entry.model)
        }

        let genByIdx = Dictionary(generations.map { ($0.idx, $0.entry) }, uniquingKeysWith: { _, new in new })
        var candidates: [Candidate] = []
        for (source, entries) in [("step", steps), ("generation", generations)] {
            for (index, pair) in entries.enumerated() {
                let entry = pair.entry
                for (usageIndex, usage) in entry.usages.enumerated() {
                    let uMid = Int(numberAt(usage, 1))
                    let modelId = uMid != 0 ? uMid : entry.modelId
                    let gen = source == "step" ? genByIdx[pair.idx] : nil
                    func matches(_ m: MetadataEntry) -> Bool { modelId == 0 || m.modelId == modelId }
                    var model = matches(entry) && !entry.model.isEmpty ? entry.model
                        : (gen.map { matches($0) && !$0.model.isEmpty ? $0.model : "" } ?? "")

                    let outputTokens = max(numberAt(usage, 3), numberAt(usage, 9) + numberAt(usage, 10))
                    let totals = TokenTotals(
                        uncached: numberAt(usage, 2),
                        cached: numberAt(usage, 5),
                        cacheCreation: numberAt(usage, 4),
                        output: outputTokens,
                        reasoning: min(outputTokens, numberAt(usage, 9))
                    )
                    if totals.total == 0 { continue }

                    let keys: [String] = [11, 12, 7].compactMap { k in
                        let id = textAt(usage, k)
                        return id.isEmpty ? nil : "antigravity:\(k):\(id)"
                    }
                    let tsMs = entry.timestampMs ?? trajectoryTimestamp ?? fallbackMs
                    let tsQuality = entry.timestampMs != nil ? 2 : (trajectoryTimestamp != nil ? 1 : 0)
                    let baseQuality = isConcreteModel(model) ? 4 : (!model.isEmpty ? 1 : 0)

                    let learned = learnedModels[modelId] ?? nil
                    let isAmbiguousLearned = learnedModels[modelId] != nil && learned == nil
                    let fallback = isAmbiguousLearned ? nil : modelIds[modelId]
                    if baseQuality < 4 {
                        if let learned, !learned.isEmpty { model = learned }
                        else if let fallback { model = fallback }
                        else if model.isEmpty { model = modelId > 0 ? "antigravity-model-\(modelId)" : "antigravity-unknown" }
                    }
                    let finalQuality = baseQuality == 4 ? 4 : (learned != nil ? 3 : (fallback != nil ? 2 : baseQuality))

                    let record = UsageRecord(
                        provider: "antigravity",
                        tsMs: tsMs,
                        model: model,
                        rateModel: nil,
                        sessionId: sessionId,
                        project: nil,
                        totals: totals,
                        reportedCost: nil,
                        speed: .standard,
                        dedupeKey: keys.first ?? "antigravity:\(sessionId):\(source):\(index):\(usageIndex)",
                        tierTurn: nil
                    )
                    candidates.append(Candidate(
                        record: record, modelId: modelId, modelQuality: finalQuality,
                        keys: keys, timestampQuality: tsQuality
                    ))
                }
            }
        }

        // Union-Find deduplication across steps, generations, and retries (exact port of T3).
        var groups: [Group] = []
        groups.reserveCapacity(candidates.count)
        var identities: [String: Int] = [:]

        func find(_ idx: Int) -> Int {
            var root = idx
            while groups[root].parent != root { root = groups[root].parent }
            var cur = idx
            while cur != root {
                let p = groups[cur].parent
                groups[cur].parent = root
                cur = p
            }
            return root
        }

        func merge(_ left: Int, _ right: Int) {
            var a = find(left)
            var b = find(right)
            if a == b { return }
            if groups[a].size < groups[b].size { swap(&a, &b) }
            let target = groups[a]
            let source = groups[b]
            let first = target.owner < source.owner ? target : source
            let bestModel = source.candidate.modelQuality == target.candidate.modelQuality ? first
                : (source.candidate.modelQuality > target.candidate.modelQuality ? source : target)
            let bestTime = (source.candidate.timestampQuality > target.candidate.timestampQuality
                || (source.candidate.timestampQuality == target.candidate.timestampQuality
                    && source.candidate.record.tsMs < target.candidate.record.tsMs)) ? source : target
            let x = target.candidate.record.totals
            let y = source.candidate.record.totals
            let mergedTotals = TokenTotals(
                uncached: max(x.uncached, y.uncached),
                cached: max(x.cached, y.cached),
                cacheCreation: max(x.cacheCreation, y.cacheCreation),
                output: max(x.output, y.output),
                reasoning: max(x.reasoning, y.reasoning)
            )
            let r = first.candidate.record
            groups[a].candidate.record = UsageRecord(
                provider: r.provider,
                tsMs: bestTime.candidate.record.tsMs,
                model: bestModel.candidate.record.model,
                rateModel: nil,
                sessionId: r.sessionId,
                project: r.project,
                totals: mergedTotals,
                reportedCost: r.reportedCost,
                speed: r.speed,
                dedupeKey: r.dedupeKey,
                tierTurn: nil
            )
            groups[a].candidate.timestampQuality = bestTime.candidate.timestampQuality
            groups[a].candidate.modelQuality = bestModel.candidate.modelQuality
            groups[a].owner = first.owner
            groups[a].size += source.size
            groups[b].parent = a
        }

        for candidate in candidates {
            let index = groups.count
            groups.append(Group(candidate: candidate, parent: index, size: 1, owner: index))
            for key in candidate.keys {
                if let existing = identities[key] { merge(index, existing) }
                identities[key] = index
            }
        }

        var out: [UsageRecord] = []
        for (index, g) in groups.enumerated() where g.parent == index {
            let r = g.candidate.record
            let rm = rateModel(for: r.model)
            out.append(UsageRecord(
                provider: r.provider, tsMs: r.tsMs, model: r.model,
                rateModel: rm == r.model ? nil : rm,
                sessionId: r.sessionId, project: r.project, totals: r.totals,
                reportedCost: r.reportedCost, speed: r.speed,
                dedupeKey: r.dedupeKey, tierTurn: nil
            ))
        }
        return out
    }
}
