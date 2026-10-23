import Foundation

struct CodexLimitsFetcher: LimitsFetcher {
    let provider = ProviderID.codex
    private static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    private struct Auth { let token: String; let accountID: String? }

    private static func readAuth() -> Auth? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return Auth(token: token, accountID: tokens["account_id"] as? String)
    }

    func isConnected() -> Bool { Self.readAuth() != nil }

    func fetch() async throws -> ProviderLimits {
        guard let auth = Self.readAuth() else { throw LimitsError.notConnected }
        do {
            return try await fetchRemote(auth)
        } catch let e as URLError {
            if let local = Self.fromSessions() { return local }
            throw e
        } catch LimitsError.http(let code) where code >= 500 {
            if let local = Self.fromSessions() { return local }
            throw LimitsError.http(code)
        }
    }

    private func fetchRemote(_ auth: Auth) async throws -> ProviderLimits {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        if let id = auth.accountID { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        let (status, data) = try await httpData(req)
        if status == 401 || status == 403 { throw LimitsError.tokenExpired }
        guard status == 200 else { throw LimitsError.http(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.badResponse
        }
        let rate = json["rate_limit"] as? [String: Any]
        let windows = ["primary_window", "secondary_window"].compactMap { key -> LimitWindow? in
            guard let w = rate?[key] as? [String: Any], let pct = jsonDouble(w["used_percent"]) else { return nil }
            let (id, label) = Self.windowName(seconds: jsonDouble(w["limit_window_seconds"]) ?? 0)
            return LimitWindow(id: id, label: label, percent: pct,
                               resetsAt: jsonDouble(w["reset_at"]).map { Date(timeIntervalSince1970: $0) })
        }
        guard !windows.isEmpty else { throw LimitsError.badResponse }
        return ProviderLimits(provider: .codex, plan: Self.plan(json["plan_type"] as? String),
                              windows: windows.sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) },
                              fetchedAt: .now)
    }

    private static func windowName(seconds: Double) -> (String, String) {
        switch seconds {
        case 18000: return ("5h", "5h")
        case 604_800: return ("week", "Week")
        case (28 * 86400)...(31 * 86400): return ("month", "Month")
        default:
            let hours = Int((seconds / 3600).rounded())
            if hours >= 48 && hours % 24 == 0 { return ("\(hours / 24)d", "\(hours / 24)d") }
            return ("\(hours)h", "\(hours)h")
        }
    }

    private static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        default: return raw.capitalized
        }
    }

    // MARK: Offline fallback: latest rate_limits snapshot written by the Codex CLI

    private static func fromSessions() -> ProviderLimits? {
        let root = home.appendingPathComponent("sessions")
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > cutoff {
                files.append((url, m))
            }
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let needle = Data("\"rate_limits\"".utf8)
            var end = data.endIndex
            while end > data.startIndex {
                let lineStart = data[data.startIndex..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
                let line = data[lineStart..<end]
                if line.range(of: needle) != nil, let l = parseSnapshot(Data(line)) { return l }
                if lineStart == data.startIndex { break }
                end = lineStart - 1
            }
        }
        return nil
    }

    private static func parseSnapshot(_ line: Data) -> ProviderLimits? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let rl = (obj["payload"] as? [String: Any])?["rate_limits"] as? [String: Any]
        else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> LimitWindow? in
            guard let w = rl[key] as? [String: Any], let pct = jsonDouble(w["used_percent"]) else { return nil }
            let (id, label) = windowName(seconds: (jsonDouble(w["window_minutes"]) ?? 0) * 60)
            let reset = jsonDouble(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            let expired = reset.map { $0 < .now } ?? false
            return LimitWindow(id: id, label: label, percent: expired ? 0 : pct, resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        return ProviderLimits(provider: .codex, plan: plan(rl["plan_type"] as? String),
                              windows: windows, fetchedAt: .now)
    }
}
