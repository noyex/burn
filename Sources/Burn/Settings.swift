import Foundation
import Observation
import ServiceManagement

enum PopoverTab: String, CaseIterable {
    case dashboard, usage, system, shelf

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .usage: "Usage"
        case .system: "System"
        case .shelf: "Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .usage: "gauge.with.dots.needle.50percent"
        case .system: "cpu"
        case .shelf: "photo.stack"
        }
    }
}

/// A reading from the System tab that can also sit on the dashboard.
enum DashboardStat: String, CaseIterable, Identifiable {
    case cpu, memory, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class Settings {
    static let highest = "highest"

    @ObservationIgnored private let defaults = UserDefaults.standard
    private var hidden: Set<String>
    private var windows: [String: String]
    /// Providers left off the dashboard. The old "hidden from the panel" choice, so it carries over.
    private var hiddenOnDashboard: Set<String>
    private var hiddenStats: Set<String>
    private var cardSizes: [String: String]
    private var cardColors: [String: String]
    private var cardWindows: [String: String]
    private var hiddenCardWindows: [String: [String]]
    private(set) var launchAtLogin: Bool
    /// Every provider, in the manual order of the panel.
    private(set) var providerOrder: [ProviderID]

    var panelLayout: PanelLayout {
        didSet { defaults.set(panelLayout.rawValue, forKey: "panel.layout") }
    }

    var panelOrder: PanelOrder {
        didSet { defaults.set(panelOrder.rawValue, forKey: "panel.order") }
    }

    var tab: PopoverTab {
        didSet { defaults.set(tab.rawValue, forKey: "popover.tab") }
    }

    /// The menu bar warns when the disk is almost full or memory runs out.
    var resourceAlerts: Bool {
        didSet { defaults.set(resourceAlerts, forKey: "menuBar.resourceAlerts") }
    }

    /// Shelf shown in the wide popover with more screenshots per row.
    var shelfExpanded: Bool {
        didSet { defaults.set(shelfExpanded, forKey: "shelf.expanded") }
    }

    /// Screenshots older than this are deleted; 0 keeps them until cleared.
    var shelfRetentionDays: Int {
        didSet { defaults.set(shelfRetentionDays, forKey: "shelf.retentionDays") }
    }

    init() {
        hidden = Set(defaults.stringArray(forKey: "menuBar.hidden") ?? [])
        let menuBarWindows = defaults.dictionary(forKey: "menuBar.windows") as? [String: String] ?? [:]
        windows = menuBarWindows
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // `--tab system` opens the preview window on a tab without saving it, for screenshots.
        let args = CommandLine.arguments
        let flag = args.contains("--preview") ? args.firstIndex(of: "--tab").flatMap { args.dropFirst($0 + 1).first } : nil
        // The dashboard is the main tab: everyone lands on it once, then the last tab sticks.
        let saved = defaults.bool(forKey: "popover.dashboardIntroduced") ? defaults.string(forKey: "popover.tab") : nil
        tab = (flag ?? saved).flatMap(PopoverTab.init) ?? .dashboard
        if flag == nil { defaults.set(true, forKey: "popover.dashboardIntroduced") }
        shelfExpanded = defaults.bool(forKey: "shelf.expanded")
        resourceAlerts = defaults.object(forKey: "menuBar.resourceAlerts") as? Bool ?? true
        shelfRetentionDays = defaults.object(forKey: "shelf.retentionDays") as? Int ?? 7
        providerOrder = PanelArrangement.order(from: defaults.stringArray(forKey: "panel.providerOrder") ?? [])
        panelLayout = defaults.string(forKey: "panel.layout").flatMap(PanelLayout.init) ?? .custom
        panelOrder = defaults.string(forKey: "panel.order").flatMap(PanelOrder.init) ?? .manual
        hiddenOnDashboard = Set(defaults.stringArray(forKey: "panel.hidden") ?? [])
        hiddenStats = Set(defaults.stringArray(forKey: "dashboard.hiddenStats") ?? [])
        cardSizes = defaults.dictionary(forKey: "panel.sizes") as? [String: String] ?? [:]
        cardColors = defaults.dictionary(forKey: "panel.colors") as? [String: String] ?? [:]
        hiddenCardWindows = defaults.dictionary(forKey: "panel.hiddenWindows") as? [String: [String]] ?? [:]
        if let saved = defaults.dictionary(forKey: "panel.windows") as? [String: String] {
            cardWindows = saved
        } else {
            // The big number used to follow the menu bar choice; start from it so nothing changes.
            cardWindows = menuBarWindows
            defaults.set(cardWindows, forKey: "panel.windows")
        }
    }

    func showsInMenuBar(_ p: ProviderID) -> Bool { !hidden.contains(p.rawValue) }

    func setShowsInMenuBar(_ p: ProviderID, _ on: Bool) {
        if on { hidden.remove(p.rawValue) } else { hidden.insert(p.rawValue) }
        defaults.set(Array(hidden), forKey: "menuBar.hidden")
    }

    /// Window id shown in the menu bar, or `highest` for whichever is most used.
    func menuBarWindow(_ p: ProviderID) -> String { windows[p.rawValue] ?? Self.defaultWindow(p) }

    func setMenuBarWindow(_ p: ProviderID, _ id: String) {
        windows[p.rawValue] = id
        defaults.set(windows, forKey: "menuBar.windows")
    }

    private static func defaultWindow(_ p: ProviderID) -> String {
        switch p {
        // The 5-hour window is the one that actually blocks work during the day.
        case .claude, .antigravity: "5h"
        // Cursor's API bucket often sits at 100% while the plan as a whole is fine.
        case .cursor: "total"
        default: highest
        }
    }

    // MARK: Dashboard

    func showsOnDashboard(_ p: ProviderID) -> Bool { !hiddenOnDashboard.contains(p.rawValue) }

    func setShowsOnDashboard(_ p: ProviderID, _ on: Bool) {
        if on { hiddenOnDashboard.remove(p.rawValue) } else { hiddenOnDashboard.insert(p.rawValue) }
        defaults.set(Array(hiddenOnDashboard), forKey: "panel.hidden")
    }

    func showsOnDashboard(_ stat: DashboardStat) -> Bool { !hiddenStats.contains(stat.rawValue) }

    func setShowsOnDashboard(_ stat: DashboardStat, _ on: Bool) {
        if on { hiddenStats.remove(stat.rawValue) } else { hiddenStats.insert(stat.rawValue) }
        defaults.set(Array(hiddenStats), forKey: "dashboard.hiddenStats")
    }

    /// Readings shown on the dashboard, in a fixed order.
    var dashboardStats: [DashboardStat] { DashboardStat.allCases.filter(showsOnDashboard) }

    // MARK: Usage cards

    /// Size saved for the Custom layout.
    func customSize(_ p: ProviderID) -> CardSize {
        cardSizes[p.rawValue].flatMap(CardSize.init) ?? (p == .claude ? .l : .m)
    }

    /// Size each of `cards` is shown at under the current layout.
    func cardSizes(for cards: [ProviderID]) -> [ProviderID: CardSize] {
        panelLayout.sizes(for: cards, custom: customSize)
    }

    /// Outside Custom, first saves what `cards` look like now and switches to Custom, so only `p` changes.
    func setCardSize(_ p: ProviderID, _ size: CardSize, cards: [ProviderID]) {
        if panelLayout != .custom {
            for (q, s) in cardSizes(for: cards) { cardSizes[q.rawValue] = s.rawValue }
            panelLayout = .custom
        }
        cardSizes[p.rawValue] = size.rawValue
        defaults.set(cardSizes, forKey: "panel.sizes")
    }

    func cardColor(_ p: ProviderID) -> CardColor {
        cardColors[p.rawValue].flatMap(CardColor.init) ?? p.brandColor
    }

    func setCardColor(_ p: ProviderID, _ color: CardColor) {
        cardColors[p.rawValue] = color.rawValue
        defaults.set(cardColors, forKey: "panel.colors")
    }

    /// Window shown big on the card, or `highest`. Separate from the menu bar choice.
    func cardWindow(_ p: ProviderID) -> String { cardWindows[p.rawValue] ?? Self.defaultWindow(p) }

    func setCardWindow(_ p: ProviderID, _ id: String) {
        cardWindows[p.rawValue] = id
        defaults.set(cardWindows, forKey: "panel.windows")
    }

    /// Windows the user switched off on the card. Stored as hidden, so windows a provider adds later show up.
    func hiddenCardWindows(_ p: ProviderID) -> Set<String> { Set(hiddenCardWindows[p.rawValue] ?? []) }

    func setShowsCardWindow(_ p: ProviderID, _ id: String, _ on: Bool) {
        var set = hiddenCardWindows(p)
        if on { set.remove(id) } else { set.insert(id) }
        hiddenCardWindows[p.rawValue] = set.isEmpty ? nil : set.sorted()
        defaults.set(hiddenCardWindows, forKey: "panel.hiddenWindows")
    }

    /// Takes `shown` as the new order of those providers and switches to manual order, so a
    /// drag freezes what was on screen.
    func reorder(_ shown: [ProviderID]) {
        providerOrder = PanelArrangement.merge(shown, into: providerOrder)
        defaults.set(providerOrder.map(\.rawValue), forKey: "panel.providerOrder")
        if panelOrder != .manual { panelOrder = .manual }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Burn: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
