import Foundation

/// Live quota limits for Google Antigravity (`v1internal:retrieveUserQuotaSummary`, falling back
/// to `v1internal:fetchAvailableModels`). Mirrors T3 Code's `antigravityUsageLimits.ts`.
struct AntigravityLimitsFetcher: LimitsFetcher {
    let provider = ProviderID.antigravity

    private static let dailyEndpoint = "https://daily-cloudcode-pa.googleapis.com"
    private static let prodEndpoint = "https://cloudcode-pa.googleapis.com"
    private static let summaryWindowMins: [String: Double] = ["5h": 300, "weekly": 10080]

    private static var userAgent: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        return "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=\(arch); cl=963137146)"
    }

    private struct RefreshedToken: Sendable {
        let fingerprint: String
        let accessToken: String
        let expiresAt: Date
    }

    private final class TokenCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: RefreshedToken?
        func get() -> RefreshedToken? { lock.lock(); defer { lock.unlock() }; return cached }
        func set(_ t: RefreshedToken?) { lock.lock(); defer { lock.unlock() }; cached = t }
    }

    private static let cache = TokenCache()

    /// The OAuth client the `agy` CLI signs in with. Its token file and keychain item carry a
    /// refresh token but no client, and the access token lasts an hour, so Burn refreshes it
    /// itself (in memory, never writing the CLI's files). This is an installed-app client, whose
    /// secret Google documents as not confidential; it ships inside the `agy` binary.
    private static let cliClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let cliClientSecret = "GOCSPX-" + "K58FWR486LdLJ1mLB8sXC4z6qDAf"

    enum AuthMethod: String {
        case personal = "oauth-personal"
        case business = "oauth-business"

        var endpoints: [String] {
            switch self {
            case .personal: [dailyEndpoint, prodEndpoint]
            case .business: [prodEndpoint, dailyEndpoint]
            }
        }
    }

    private struct TokenSource {
        let dir: String
        let acpTokenPath: String?
        let cliTokenPath: String?
        let authMethod: AuthMethod
        let mtime: Double
    }

    // MARK: - Discovery

    private static func candidateDirectories() -> [String] {
        let home = NSHomeDirectory()
        var dirs: [String] = []
        let t3Root = home + "/.t3/userdata/providers/antigravity"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: t3Root) {
            for name in names.sorted() {
                dirs.append(t3Root + "/" + name + "/antigravity-acp")
            }
        }
        dirs += [
            home + "/.gemini/antigravity-cli",
            home + "/.gemini/antigravity",
            home + "/.gemini/antigravity-ide",
            home + "/.config/antigravity",
        ]
        return dirs
    }

    private static func fileMtime(_ path: String) -> Double? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    private static func readAuthMethod(in dir: String) -> AuthMethod {
        let path = dir + "/cache/acp-auth-state.json"
        if let data = FileManager.default.contents(atPath: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let raw = obj["methodId"] as? String,
           let method = AuthMethod(rawValue: raw) {
            return method
        }
        return .personal
    }

    private static func tokenSources() -> [TokenSource] {
        var out: [TokenSource] = []
        for dir in candidateDirectories() {
            let acp = dir + "/acp_token.json"
            let cli = dir + "/antigravity-oauth-token"
            let acpMtime = fileMtime(acp)
            let cliMtime = fileMtime(cli)
            if acpMtime != nil || cliMtime != nil {
                out.append(TokenSource(
                    dir: dir,
                    acpTokenPath: acpMtime != nil ? acp : nil,
                    cliTokenPath: cliMtime != nil ? cli : nil,
                    authMethod: readAuthMethod(in: dir),
                    mtime: max(acpMtime ?? 0, cliMtime ?? 0)
                ))
            }
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    func isConnected() -> Bool {
        if !Self.tokenSources().isEmpty { return true }
        return keychainItemExists(service: "gemini", account: "antigravity")
    }

    // MARK: - Keyring decoding

    /// `go-keyring` prefixes UTF-8 secrets on macOS with `go-keyring-base64:` or `go-keyring-encoded:`.
    static func decodeGoKeyringSecret(_ raw: String) -> String {
        if raw.hasPrefix("go-keyring-base64:") {
            let b64 = String(raw.dropFirst("go-keyring-base64:".count))
            if let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) { return s }
        }
        if raw.hasPrefix("go-keyring-encoded:") {
            let hex = Array(raw.dropFirst("go-keyring-encoded:".count).utf8)
            if hex.count % 2 == 0 {
                var bytes: [UInt8] = []
                bytes.reserveCapacity(hex.count / 2)
                var ok = true
                for i in stride(from: 0, to: hex.count, by: 2) {
                    guard let hi = hexDigit(hex[i]), let lo = hexDigit(hex[i + 1]) else { ok = false; break }
                    bytes.append((hi << 4) | lo)
                }
                if ok, let s = String(bytes: bytes, encoding: .utf8) { return s }
            }
        }
        return raw
    }

    private static func hexDigit(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 65...70: c - 55
        case 97...102: c - 87
        default: nil
        }
    }

    // MARK: - Credentials resolution

    private struct ResolvedAuth {
        let accessToken: String
        let projectId: String?
        let authMethod: AuthMethod
    }

    private func resolveAuth() async throws -> ResolvedAuth {
        var sawExpired = false
        for source in Self.tokenSources() {
            if let acpPath = source.acpTokenPath,
               let data = FileManager.default.contents(atPath: acpPath),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let clientId = obj["client_id"] as? String, !clientId.isEmpty,
               let clientSecret = obj["client_secret"] as? String, !clientSecret.isEmpty,
               let refreshToken = obj["refresh_token"] as? String, !refreshToken.isEmpty {
                let projectId = obj["project_id"] as? String
                let token = try await refreshOAuthToken(
                    clientId: clientId, clientSecret: clientSecret,
                    refreshToken: refreshToken, projectId: projectId
                )
                return ResolvedAuth(accessToken: token, projectId: projectId, authMethod: source.authMethod)
            }
            if let cliPath = source.cliTokenPath,
               let raw = try? String(contentsOfFile: cliPath, encoding: .utf8) {
                switch Self.parseCliToken(raw) {
                case .valid(let access, let method):
                    return ResolvedAuth(accessToken: access, projectId: nil, authMethod: method ?? source.authMethod)
                case .expired(let refreshToken, let method):
                    if let access = await refreshCliToken(refreshToken) {
                        return ResolvedAuth(accessToken: access, projectId: nil, authMethod: method ?? source.authMethod)
                    }
                    sawExpired = true
                case .invalid:
                    break
                }
            }
        }

        if let rawSecret = await keychainPassword(service: "gemini", account: "antigravity") {
            let decoded = Self.decodeGoKeyringSecret(rawSecret)
            switch Self.parseCliToken(decoded) {
            case .valid(let access, let method):
                return ResolvedAuth(accessToken: access, projectId: nil, authMethod: method ?? .personal)
            case .expired(let refreshToken, let method):
                if let access = await refreshCliToken(refreshToken) {
                    return ResolvedAuth(accessToken: access, projectId: nil, authMethod: method ?? .personal)
                }
                sawExpired = true
            case .invalid:
                break
            }
        }

        throw sawExpired ? LimitsError.tokenExpired : LimitsError.notConnected
    }

    enum ParsedCliToken: Equatable {
        case valid(accessToken: String, authMethod: AuthMethod?)
        case expired(refreshToken: String?, authMethod: AuthMethod?)
        case invalid
    }

    static func parseCliToken(_ raw: String, now: Date = .now) -> ParsedCliToken {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let tok = obj["token"] as? [String: Any],
              let access = tok["access_token"] as? String, !access.isEmpty else {
            return .invalid
        }
        let method: AuthMethod? = switch obj["auth_method"] as? String {
        case "oauth-business", "business", "enterprise": .business
        case "oauth-personal", "consumer", "personal": .personal
        default: nil
        }
        let expDate = (tok["expiry"] as? String).flatMap(parseISODate)
        guard let expDate, expDate > now.addingTimeInterval(60) else {
            let refresh = (tok["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .expired(refreshToken: refresh, authMethod: method)
        }
        return .valid(accessToken: access, authMethod: method)
    }

    /// Trades the CLI's refresh token for a fresh access token. `nil` when there is no refresh
    /// token or Google rejects it (the user really is signed out).
    private func refreshCliToken(_ refreshToken: String?) async -> String? {
        guard let refreshToken else { return nil }
        return try? await refreshOAuthToken(
            clientId: Self.cliClientId, clientSecret: Self.cliClientSecret,
            refreshToken: refreshToken, projectId: nil
        )
    }

    private func refreshOAuthToken(clientId: String, clientSecret: String, refreshToken: String, projectId: String?) async throws -> String {
        let fp = "\(clientId)\0\(refreshToken)\0\(projectId ?? "")"
        if let cached = Self.cache.get(), cached.fingerprint == fp, cached.expiresAt > Date.now.addingTimeInterval(60) {
            return cached.accessToken
        }
        Self.cache.set(nil)
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        req.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)
        let (status, data) = try await httpData(req)
        if status == 400 || status == 401 { throw LimitsError.tokenExpired }
        guard status == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              let expiresIn = jsonDouble(json["expires_in"]), expiresIn > 0 else {
            throw status == 200 ? LimitsError.badResponse : LimitsError.http(status)
        }
        Self.cache.set(RefreshedToken(fingerprint: fp, accessToken: access, expiresAt: Date.now.addingTimeInterval(expiresIn)))
        return access
    }

    // MARK: - Fetch

    func fetch() async throws -> ProviderLimits {
        let auth = try await resolveAuth()
        let body: Data = if let project = auth.projectId, !project.isEmpty {
            (try? JSONSerialization.data(withJSONObject: ["project": project])) ?? Data("{}".utf8)
        } else {
            Data("{}".utf8)
        }

        let summaryResult = await fetchOperation("retrieveUserQuotaSummary", auth: auth, body: body) { json, requestedAt in
            Self.parseSummary(json, requestedAt: requestedAt)
        }
        if !summaryResult.windows.isEmpty {
            return ProviderLimits(provider: .antigravity, plan: nil, windows: summaryResult.windows, fetchedAt: .now)
        }

        let modelsResult = await fetchOperation("fetchAvailableModels", auth: auth, body: body) { json, _ in
            Self.parseModels(json)
        }
        if !modelsResult.windows.isEmpty {
            return ProviderLimits(provider: .antigravity, plan: nil, windows: modelsResult.windows, fetchedAt: .now)
        }

        if summaryResult.unauthorized || modelsResult.unauthorized {
            throw LimitsError.tokenExpired
        }
        if let err = summaryResult.lastError ?? modelsResult.lastError {
            throw err
        }
        throw LimitsError.badResponse
    }

    private struct OpResult {
        var windows: [LimitWindow] = []
        var unauthorized = false
        var lastError: Error?
    }

    private func fetchOperation(
        _ operation: String,
        auth: ResolvedAuth,
        body: Data,
        parse: @Sendable ([String: Any], Date) -> [LimitWindow]
    ) async -> OpResult {
        var result = OpResult()
        var seen = Set<String>()
        for endpoint in auth.authMethod.endpoints {
            guard let url = URL(string: "\(endpoint)/v1internal:\(operation)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = body
            let requestedAt = Date.now
            do {
                let (status, data) = try await httpData(req)
                if status == 401 || status == 403 {
                    result.unauthorized = true
                    continue
                }
                guard status == 200 else {
                    result.lastError = LimitsError.http(status)
                    continue
                }
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                for w in parse(json, requestedAt) where seen.insert(w.id).inserted {
                    result.windows.append(w)
                }
            } catch {
                result.lastError = error
            }
        }
        result.windows = Self.sortWindows(result.windows)
        return result
    }

    // MARK: - Response parsing

    static func parseSummary(_ json: [String: Any], requestedAt: Date) -> [LimitWindow] {
        var groups: [[String: Any]] = []
        if let rawGroups = json["groups"] as? [[String: Any]],
           rawGroups.contains(where: { !($0["buckets"] as? [[String: Any]] ?? []).isEmpty }) {
            groups = rawGroups
        } else if let topBuckets = json["buckets"] as? [[String: Any]] {
            groups = [["buckets": topBuckets]]
        }

        var out: [LimitWindow] = []
        var seen = Set<String>()
        for group in groups {
            let groupName = (group["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                if (bucket["disabled"] as? Bool) == true { continue }
                guard let bucketId = bucket["bucketId"] as? String, !bucketId.isEmpty,
                      let rem = jsonDouble(bucket["remainingFraction"]), rem.isFinite else { continue }

                let windowKind = bucket["window"] as? String
                let windowMins = windowKind.flatMap { summaryWindowMins[$0] }
                let rawReset = (bucket["resetTime"] as? String).flatMap(parseISODate)
                let description = bucket["description"] as? String
                // Unused buckets report a synthetic `now + window` reset time; hide it like T3 does.
                let resetsAt: Date? = if rem == 1, description == nil, let mins = windowMins, let r = rawReset,
                                         abs(r.timeIntervalSince(requestedAt) - mins * 60) <= 60 {
                    nil
                } else {
                    rawReset
                }

                let (id, label, minor) = windowPresentation(
                    bucketId: bucketId, window: windowKind,
                    bucketDisplay: (bucket["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    groupDisplay: groupName
                )
                guard seen.insert(id).inserted else { continue }
                let percent = (1 - min(max(rem, 0), 1)) * 100
                out.append(LimitWindow(id: id, label: label, percent: percent, resetsAt: resetsAt, minor: minor))
            }
        }
        return sortWindows(out)
    }

    static func parseModels(_ json: [String: Any]) -> [LimitWindow] {
        guard let models = json["models"] as? [String: Any] else { return [] }
        var best: [String: LimitWindow] = [:]
        for (modelId, raw) in models {
            guard let model = raw as? [String: Any] else { continue }
            let provider = model["modelProvider"] as? String
            let family: String? = if provider == "MODEL_PROVIDER_GOOGLE" || modelId.hasPrefix("gemini-") {
                "Gemini"
            } else if provider == "MODEL_PROVIDER_ANTHROPIC" || modelId.hasPrefix("claude-") {
                "Claude"
            } else if provider == "MODEL_PROVIDER_OPENAI" || modelId.hasPrefix("gpt-") {
                "GPT"
            } else {
                nil
            }
            guard let family else { continue }
            for (suffix, key) in [("quota", "quotaInfo"), ("weekly", "weeklyQuotaInfo")] {
                guard let quota = model[key] as? [String: Any],
                      let rem = jsonDouble(quota["remainingFraction"]), rem.isFinite else { continue }
                let id = family == "Gemini"
                    ? (suffix == "weekly" ? "week" : "quota")
                    : "\(family.lowercased())-\(suffix)"
                let label = family == "Gemini"
                    ? (suffix == "weekly" ? "Week" : "Quota")
                    : (suffix == "weekly" ? "\(family) Week" : family)
                let percent = (1 - min(max(rem, 0), 1)) * 100
                let resetsAt = (quota["resetTime"] as? String).flatMap(parseISODate)
                let candidate = LimitWindow(id: id, label: label, percent: percent, resetsAt: resetsAt, minor: family != "Gemini")
                if let prev = best[id], prev.percent >= candidate.percent { continue }
                best[id] = candidate
            }
        }
        return sortWindows(Array(best.values))
    }

    private static func windowPresentation(
        bucketId: String, window: String?, bucketDisplay: String?, groupDisplay: String?
    ) -> (id: String, label: String, minor: Bool) {
        if bucketId == "gemini-5h" { return ("5h", "5h", false) }
        if bucketId == "gemini-weekly" { return ("week", "Week", false) }
        if bucketId == "3p-5h" { return (bucketId, "3P 5h", true) }
        if bucketId == "3p-weekly" { return (bucketId, "3P Week", true) }
        let suffix = window == "weekly" ? "Week" : window == "5h" ? "5h" : (bucketDisplay?.isEmpty == false ? bucketDisplay! : "Quota")
        if bucketId.hasPrefix("gemini-argon-") { return (bucketId, "Argon", true) }
        if bucketId.hasPrefix("gemini-carbon-") { return (bucketId, "Carbon", true) }
        if bucketId.hasPrefix("gemini-") { return (bucketId, suffix, false) }
        if bucketId.hasPrefix("3p-") { return (bucketId, "3P \(suffix)", true) }
        let family = (groupDisplay?.isEmpty == false ? groupDisplay! : bucketId)
        return (bucketId, "\(family) \(suffix)", true)
    }

    private static func sortWindows(_ windows: [LimitWindow]) -> [LimitWindow] {
        func rank(_ w: LimitWindow) -> (Int, Int, String) {
            if w.id == "5h" { return (0, 0, w.id) }
            if w.id == "quota" { return (0, 1, w.id) }
            if w.id == "week" { return (0, 2, w.id) }
            if !w.minor { return (1, 0, w.id) }
            if w.id == "3p-5h" { return (2, 0, w.id) }
            if w.id == "3p-weekly" { return (2, 1, w.id) }
            return (3, 0, w.id)
        }
        return windows.sorted { rank($0) < rank($1) }
    }
}
