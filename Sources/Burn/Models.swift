import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, codex, cursor

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// One rate-limit window of a provider, e.g. Claude's 5-hour or weekly limit.
struct LimitWindow: Identifiable, Hashable, Sendable {
    /// Stable key used to remember the user's menu bar choice, e.g. "5h", "week", "month", "total", "api".
    let id: String
    /// Short label shown in the UI, e.g. "5h", "Week", "Month", "API".
    let label: String
    /// 0...100 (may exceed 100 if the provider reports overage).
    let percent: Double
    let resetsAt: Date?
}

struct ProviderLimits: Sendable {
    let provider: ProviderID
    /// Human-readable plan, e.g. "Max 5x", "Pro", "Free". Nil if unknown.
    let plan: String?
    /// Ordered from shortest to longest window.
    let windows: [LimitWindow]
    let fetchedAt: Date
}

enum LimitsError: LocalizedError {
    case notConnected
    case tokenExpired
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not signed in"
        case .tokenExpired: "Session expired, open the app to sign in again"
        case .http(let code): "Request failed (\(code))"
        case .badResponse: "Unexpected response"
        }
    }
}

protocol LimitsFetcher: Sendable {
    var provider: ProviderID { get }
    /// Cheap local check (credentials present). Must not hit the network.
    func isConnected() -> Bool
    func fetch() async throws -> ProviderLimits
}

enum Period: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7D"
        case .month: "30D"
        case .all: "All"
        }
    }
}

enum BucketUnit: Sendable { case hour, day, week }

struct UsageBucket: Sendable, Identifiable {
    let start: Date
    let cost: [ProviderID: Double]
    var id: Date { start }
    var total: Double { cost.values.reduce(0, +) }
}

struct UsageSummary: Sendable {
    let period: Period
    let cost: Double
    let tokens: Int64
    let byProvider: [ProviderID: Double]
    /// Contiguous buckets (zero-filled) covering the period, oldest first.
    let buckets: [UsageBucket]
    let unit: BucketUnit
}
