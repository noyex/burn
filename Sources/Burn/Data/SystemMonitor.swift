import Foundation
import Observation

/// Live readings for the System tab, plus the low disk / memory warning in the menu bar.
/// Reads every couple of seconds only while the tab is on screen; the warning needs one cheap
/// reading a minute.
@MainActor
@Observable
final class SystemMonitor {
    static let appCount = 4
    static let historyLength = 30
    /// Under this much free space the menu bar warns, and under `diskFull` it turns red.
    nonisolated static let diskLow: Int64 = 10_000_000_000
    nonisolated static let diskFull: Int64 = 3_000_000_000

    private(set) var snapshot = SystemSnapshot()
    /// Recent CPU readings, oldest first, for the sparkline.
    private(set) var cpuHistory: [Double] = []
    /// What the menu bar warns about right now, if anything.
    private(set) var alert: SystemAlert?

    /// Called when `alert` changes.
    @ObservationIgnored var onAlertChange: (() -> Void)?

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var alertTimer: Timer?
    @ObservationIgnored private var lastSample: Date?

    /// Starts or stops the fast readings behind the System tab.
    func setLive(_ live: Bool) {
        guard live != (liveTask != nil) else { return }
        liveTask?.cancel()
        liveTask = nil
        guard live else { return }
        // A gap in the line would read as a drop; start it over after a pause.
        if (lastSample.map { Date.now.timeIntervalSince($0) > 10 }) ?? true { cpuHistory = [] }
        liveTask = Task { [weak self, sampler] in
            await sampler.reset()
            // A quick first pair, so the rates show up right away.
            var delay: Duration = .milliseconds(600)
            while !Task.isCancelled {
                let snap = await sampler.sample(apps: Self.appCount)
                guard !Task.isCancelled, let self else { return }
                self.apply(snap)
                try? await Task.sleep(for: delay)
                delay = .seconds(2)
            }
        }
    }

    private func apply(_ snap: SystemSnapshot) {
        // Keep the last rates through a reading that can't compute them, so nothing blinks.
        var next = snap
        if next.cpu == nil { next.cpu = snapshot.cpu }
        if next.network == nil { next.network = snapshot.network }
        if next.apps.isEmpty { next.apps = snapshot.apps }
        if next.disk == nil { next.disk = snapshot.disk }
        if next.memory == nil { next.memory = snapshot.memory }
        snapshot = next
        lastSample = .now
        if let cpu = snap.cpu {
            cpuHistory.append(cpu)
            if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
        }
        setAlert(SystemAlert(disk: next.disk, pressure: next.memory?.pressure ?? .normal, margin: diskMargin))
    }

    // MARK: Menu bar warning

    /// Checks disk and memory once a minute while `enabled`; clears the warning otherwise.
    func watchAlerts(_ enabled: Bool) {
        alertTimer?.invalidate()
        alertTimer = nil
        guard enabled else { setAlert(nil); return }
        Task { await checkAlert() }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAlert() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        alertTimer = t
    }

    private func checkAlert() async {
        let reading = await sampler.alertReading()
        guard alertTimer != nil else { return }
        setAlert(SystemAlert(disk: reading.disk ?? snapshot.disk, pressure: reading.pressure, margin: diskMargin))
    }

    /// Once the disk warning shows, it waits for this much more room before it goes away, so
    /// free space hovering at the line doesn't make the menu bar flicker.
    private var diskMargin: Int64 {
        if case .disk = alert?.kind { 1_000_000_000 } else { 0 }
    }

    private func setAlert(_ next: SystemAlert?) {
        // The live readings also refresh it, but only while warnings are on.
        let next = alertTimer == nil ? nil : next
        guard next != alert else { return }
        alert = next
        onAlertChange?()
    }
}

/// Low disk space or memory pressure, as the menu bar shows it.
struct SystemAlert: Equatable {
    enum Kind: Equatable { case disk(free: Int64), memory }
    let kind: Kind
    let level: MenuBarImage.Level

    /// The more urgent of the two, or nil when both are fine.
    /// `margin` is subtracted from free space, to keep a warning that is already showing.
    init?(disk: SystemSnapshot.Disk?, pressure: MemoryPressure, margin: Int64 = 0) {
        let diskLevel = disk.map { MenuBarImage.Level(free: $0.free - margin) } ?? .normal
        let memoryLevel = MenuBarImage.Level(pressure)
        if let disk, diskLevel != .normal, diskLevel == .full || memoryLevel != .full {
            self.init(kind: .disk(free: disk.free), level: diskLevel)
        } else if memoryLevel != .normal {
            self.init(kind: .memory, level: memoryLevel)
        } else {
            return nil
        }
    }

    init(kind: Kind, level: MenuBarImage.Level) {
        self.kind = kind
        self.level = level
    }

    var symbol: String {
        switch kind {
        case .disk: "internaldrive.fill"
        case .memory: "memorychip.fill"
        }
    }

    /// Next to the symbol in the menu bar.
    var text: String {
        switch kind {
        case .disk(let free): Format.bytes(free)
        case .memory: "RAM"
        }
    }

    var description: String {
        switch kind {
        case .disk(let free): "Disk almost full, \(Format.bytes(free)) free"
        case .memory: level == .full ? "Out of memory" : "Memory is running low"
        }
    }
}
