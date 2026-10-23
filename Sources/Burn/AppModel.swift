import Foundation
import Observation

enum LimitState {
    case loading
    case loaded(ProviderLimits)
    /// Credentials are missing or expired; the user has to sign in with the provider's CLI.
    case signedOut
    /// Keeps the last good value so a transient failure doesn't blank the UI.
    case failed(String, last: ProviderLimits?)

    var limits: ProviderLimits? {
        switch self {
        case .loading, .signedOut: nil
        case .loaded(let l): l
        case .failed(_, let last): last
        }
    }
}

@MainActor
@Observable
final class AppModel {
    nonisolated static let warnPercent: Double = 80

    private(set) var connected: [ProviderID] = []
    private(set) var limits: [ProviderID: LimitState] = [:]
    private(set) var usage: UsageSummary?
    private(set) var lastSync: Date?
    private(set) var syncing = false
    /// Percent of the current import, only while one is running.
    private(set) var importPercent: Int?
    /// False until at least one usage record exists (no Claude Code / Codex logs yet).
    private(set) var hasUsage = true
    private(set) var usageError: String?

    var period: Period = .all {
        didSet { if period != oldValue { Task { await loadUsage() } } }
    }

    let settings = Settings()
    let shelf: ShelfStore

    /// Called whenever something shown in the menu bar changes.
    @ObservationIgnored var onMenuBarChange: (() -> Void)?

    @ObservationIgnored private let fetchers: [any LimitsFetcher] = [
        ClaudeLimitsFetcher(), CodexLimitsFetcher(), CursorLimitsFetcher(),
    ]
    @ObservationIgnored private let db = UsageDatabase()
    @ObservationIgnored private var limitsFetchedAt: Date?
    @ObservationIgnored private var refreshingLimits = false
    @ObservationIgnored private var timers: [Timer] = []

    init() {
        shelf = ShelfStore(settings: settings)
    }

    func start() {
        shelf.start()
        Task { await refreshLimits() }
        Task { await loadUsage(); await sync() }
        schedule(every: 120) { [weak self] in await self?.refreshLimits() }
        schedule(every: 300) { [weak self] in await self?.sync() }
    }

    func popoverOpened() {
        if (limitsFetchedAt.map { Date.now.timeIntervalSince($0) > 30 }) ?? true {
            Task { await refreshLimits() }
        }
        if (lastSync.map { Date.now.timeIntervalSince($0) > 60 }) ?? true {
            Task { await sync() }
        }
    }

    // MARK: Menu bar

    struct MenuBarEntry {
        let provider: ProviderID
        let percent: Double
        let resetsAt: Date?
    }

    var menuBarEntries: [MenuBarEntry] {
        connected.compactMap { p in
            guard settings.showsInMenuBar(p), let l = limits[p]?.limits,
                  let w = menuBarWindow(for: l) else { return nil }
            return MenuBarEntry(provider: p, percent: w.percent, resetsAt: w.resetsAt)
        }
    }

    func menuBarWindow(for limits: ProviderLimits) -> LimitWindow? {
        let choice = settings.menuBarWindow(limits.provider)
        if choice != Settings.highest, let w = limits.windows.first(where: { $0.id == choice }) {
            return w
        }
        return limits.windows.max { $0.percent < $1.percent }
    }

    func settingsChanged() { onMenuBarChange?() }

    // MARK: Loading

    private func refreshLimits() async {
        guard !refreshingLimits else { return }
        refreshingLimits = true
        defer { refreshingLimits = false }
        limitsFetchedAt = .now

        // Re-detect on every refresh so signing in or out of a provider shows up without a restart.
        // isConnected() spawns `security`, so keep it off the main actor.
        let fetchers = fetchers
        let now = await Task.detached { fetchers.filter { $0.isConnected() }.map(\.provider) }.value
        if now != connected {
            for p in connected where !now.contains(p) { limits[p] = nil }
            for p in now where limits[p] == nil { limits[p] = .loading }
            connected = now
            onMenuBarChange?()
        }

        await withTaskGroup(of: (ProviderID, Result<ProviderLimits, Error>).self) { group in
            for f in fetchers where connected.contains(f.provider) {
                group.addTask {
                    do { return (f.provider, .success(try await f.fetch())) }
                    catch { return (f.provider, .failure(error)) }
                }
            }
            for await (p, result) in group {
                switch result {
                case .success(let l): limits[p] = .loaded(l)
                case .failure(LimitsError.tokenExpired), .failure(LimitsError.notConnected): limits[p] = .signedOut
                case .failure(let e): limits[p] = .failed(e.localizedDescription, last: limits[p]?.limits)
                }
            }
        }
        onMenuBarChange?()
    }

    private func sync() async {
        guard !syncing else { return }
        syncing = true
        do {
            _ = try await UsageImporter.shared.run { [weak self] p in
                guard p.total > 0 else { return }
                let pct = p.done * 100 / p.total
                Task { @MainActor in
                    // Hops can land after sync() finished; ignore them then.
                    if let self, self.syncing, self.importPercent != pct { self.importPercent = pct }
                }
            }
            lastSync = .now
        } catch {
            NSLog("Burn: import failed: \(error)")
        }
        syncing = false
        importPercent = nil
        await loadUsage()
    }

    private func loadUsage() async {
        let period = period
        let db = db
        let (result, any) = await Task.detached {
            (Result { try db.summary(for: period) }, (try? db.hasAnyUsage()) ?? false)
        }.value
        hasUsage = any
        guard period == self.period else { return }
        switch result {
        case .success(let s): usage = s; usageError = nil
        case .failure(let e): usageError = e.localizedDescription
        }
    }

    private func schedule(every seconds: TimeInterval, _ work: @escaping @MainActor () async -> Void) {
        let t = Timer(timeInterval: seconds, repeats: true) { _ in Task { @MainActor in await work() } }
        t.tolerance = seconds * 0.1
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }
}
