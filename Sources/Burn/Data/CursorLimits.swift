import Foundation
import SQLite3

struct CursorLimitsFetcher: LimitsFetcher {
    let provider = ProviderID.cursor
    private static let dbPath = NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    func isConnected() -> Bool {
        keychainItemExists(service: "cursor-access-token", account: "cursor-user")
            || Self.itemValue("cursorAuth/accessToken") != nil
    }

    func fetch() async throws -> ProviderLimits {
        var token = await keychainPassword(service: "cursor-access-token", account: "cursor-user")
        if token == nil { token = Self.itemValue("cursorAuth/accessToken") }
        guard let token else { throw LimitsError.notConnected }

        var req = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.httpBody = Data("{}".utf8)
        let (status, data) = try await httpData(req)
        if status == 401 || status == 403 { throw LimitsError.tokenExpired }
        guard status == 200 else { throw LimitsError.http(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.badResponse
        }
        if json["code"] as? String == "unauthenticated" { throw LimitsError.tokenExpired }

        let reset = jsonDouble(json["billingCycleEnd"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let usage = json["planUsage"] as? [String: Any]
        var windows: [LimitWindow] = []
        var total = jsonDouble(usage?["totalPercentUsed"])
        if total == nil, let inc = jsonDouble(usage?["includedSpend"]), let lim = jsonDouble(usage?["limit"]), lim > 0 {
            total = inc / lim * 100
        }
        if let total { windows.append(LimitWindow(id: "total", label: "Month", percent: total, resetsAt: reset)) }
        if let api = jsonDouble(usage?["apiPercentUsed"]) {
            windows.append(LimitWindow(id: "api", label: "API", percent: api, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw LimitsError.badResponse }
        return ProviderLimits(provider: .cursor, plan: Self.plan(Self.itemValue("cursorAuth/stripeMembershipType")),
                              windows: windows, fetchedAt: .now)
    }

    private static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "pro": return "Pro"
        case "pro_plus": return "Pro+"
        case "ultra": return "Ultra"
        case "free_trial": return "Trial"
        case "business", "team": return "Team"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Reads one ItemTable value from Cursor's state DB, read-only (Cursor may have it open).
    private static func itemValue(_ key: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        let uri = "file:" + (dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        let v = String(cString: c).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        return v.isEmpty ? nil : v
    }
}
