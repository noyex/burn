import Foundation

struct ClaudeLimitsFetcher: LimitsFetcher {
    let provider = ProviderID.claude
    private static let service = "Claude Code-credentials"

    func isConnected() -> Bool {
        keychainItemExists(service: Self.service)
    }

    func fetch() async throws -> ProviderLimits {
        guard let raw = await keychainPassword(service: Self.service),
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw LimitsError.notConnected }

        // Never refresh: that would invalidate Claude Code's own token.
        if let exp = jsonDouble(oauth["expiresAt"]), Date(timeIntervalSince1970: exp / 1000) < .now {
            throw LimitsError.tokenExpired
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (status, data) = try await httpData(req)
        if status == 401 { throw LimitsError.tokenExpired }
        guard status == 200 else { throw LimitsError.http(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.badResponse
        }

        let keys: [(String, String, String)] = [
            ("five_hour", "5h", "5h"), ("seven_day", "week", "Week"),
            ("seven_day_opus", "week_opus", "Opus"), ("seven_day_sonnet", "week_sonnet", "Sonnet"),
        ]
        let windows = keys.compactMap { key, id, label -> LimitWindow? in
            guard let w = json[key] as? [String: Any], let pct = jsonDouble(w["utilization"]) else { return nil }
            return LimitWindow(id: id, label: label, percent: pct,
                               resetsAt: (w["resets_at"] as? String).flatMap(parseISODate))
        }
        guard !windows.isEmpty else { throw LimitsError.badResponse }

        return ProviderLimits(
            provider: .claude,
            plan: Self.plan(sub: oauth["subscriptionType"] as? String, tier: oauth["rateLimitTier"] as? String),
            windows: windows, fetchedAt: .now)
    }

    private static func plan(sub: String?, tier: String?) -> String? {
        guard let sub, !sub.isEmpty else { return nil }
        if sub.lowercased() == "max" {
            if tier?.contains("20x") == true { return "Max 20x" }
            if tier?.contains("5x") == true { return "Max 5x" }
        }
        return sub.capitalized
    }
}
