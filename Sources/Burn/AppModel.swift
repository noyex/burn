import Foundation
import Observation

enum LimitState {
    case loading
    case loaded(ProviderLimits)
    /// Keeps the last good value so a transient failure doesn't blank the UI.
    case failed(String, last: ProviderLimits?)

    var limits: ProviderLimits? {
        switch self {
        case .loading: nil
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
    private(set) var usageError: String?

    var period: Period = .all {
        didSet { if period != oldValue { Task { await loadUsage() } } }
    }

    let settings = Settings()

    /// Called whenever something shown in the menu bar changes.
    @ObservationIgnored var onMenuBarChange: (() -> Void)?

    @ObservationIgnored private let fetchers: [any LimitsFetcher] = [
        ClaudeLimitsFetcher(), CodexLimitsFetcher(), CursorLimitsFetcher(),
    ]
    @ObservationIgnored private let db = UsageDatabase()
    @ObservationIgnored private var limitsFetchedAt: Date?
    @ObservationIgnored private var timers: [Timer] = []

    func start() {
        connected = fetchers.filter { $0.isConnected() }.map(\.provider)
        for p in connected { limits[p] = .loading }
        onMenuBarChange?()
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
        limitsFetchedAt = .now
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
                case .failure(let e): limits[p] = .failed(e.localizedDescription, last: limits[p]?.limits)
                }
            }
        }
        onMenuBarChange?()
    }

    private func sync() async {
        guard !syncing else { return }
        syncing = true
        if await runUsageSync() { lastSync = .now }
        syncing = false
        await loadUsage()
    }

    private func loadUsage() async {
        let period = period
        let db = db
        let result = await Task.detached { Result { try db.summary(for: period) } }.value
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
