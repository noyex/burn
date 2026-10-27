import Foundation
import Observation
import ServiceManagement

enum PopoverTab: String, CaseIterable {
    case usage, shelf

    var title: String {
        switch self {
        case .usage: "Usage"
        case .shelf: "Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .usage: "gauge.with.dots.needle.50percent"
        case .shelf: "photo.stack"
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
    private var hiddenInPanel: Set<String>
    private var cardSizes: [String: String]
    private var cardColors: [String: String]
    private var cardWindows: [String: String]
    private(set) var launchAtLogin: Bool
    /// Every provider, in the manual order of the panel.
    private(set) var providerOrder: [ProviderID]

    var panelLayout: PanelLayout {
        didSet { defaults.set(panelLayout.rawValue, forKey: "panel.layout") }
    }

    var panelOrder: PanelOrder {
        didSet { defaults.set(panelOrder.rawValue, forKey: "panel.order") }
    }

    var showsSpending: Bool {
        didSet { defaults.set(showsSpending, forKey: "panel.showsSpending") }
    }

    var tab: PopoverTab {
        didSet { defaults.set(tab.rawValue, forKey: "popover.tab") }
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
        tab = defaults.string(forKey: "popover.tab").flatMap(PopoverTab.init) ?? .usage
        shelfExpanded = defaults.bool(forKey: "shelf.expanded")
        shelfRetentionDays = defaults.object(forKey: "shelf.retentionDays") as? Int ?? 7
        providerOrder = PanelArrangement.order(from: defaults.stringArray(forKey: "panel.providerOrder") ?? [])
        panelLayout = defaults.string(forKey: "panel.layout").flatMap(PanelLayout.init) ?? .custom
        panelOrder = defaults.string(forKey: "panel.order").flatMap(PanelOrder.init) ?? .manual
        showsSpending = defaults.object(forKey: "panel.showsSpending") as? Bool ?? true
        hiddenInPanel = Set(defaults.stringArray(forKey: "panel.hidden") ?? [])
        cardSizes = defaults.dictionary(forKey: "panel.sizes") as? [String: String] ?? [:]
        cardColors = defaults.dictionary(forKey: "panel.colors") as? [String: String] ?? [:]
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
        case .claude: "5h"
        // Cursor's API bucket often sits at 100% while the plan as a whole is fine.
        case .cursor: "total"
        default: highest
        }
    }

    // MARK: Panel

    func showsInPanel(_ p: ProviderID) -> Bool { !hiddenInPanel.contains(p.rawValue) }

    func setShowsInPanel(_ p: ProviderID, _ on: Bool) {
        if on { hiddenInPanel.remove(p.rawValue) } else { hiddenInPanel.insert(p.rawValue) }
        defaults.set(Array(hiddenInPanel), forKey: "panel.hidden")
    }

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
