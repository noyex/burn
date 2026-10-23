import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class Settings {
    static let highest = "highest"

    @ObservationIgnored private let defaults = UserDefaults.standard
    private var hidden: Set<String>
    private var windows: [String: String]
    private(set) var launchAtLogin: Bool

    init() {
        hidden = Set(defaults.stringArray(forKey: "menuBar.hidden") ?? [])
        windows = defaults.dictionary(forKey: "menuBar.windows") as? [String: String] ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showsInMenuBar(_ p: ProviderID) -> Bool { !hidden.contains(p.rawValue) }

    func setShowsInMenuBar(_ p: ProviderID, _ on: Bool) {
        if on { hidden.remove(p.rawValue) } else { hidden.insert(p.rawValue) }
        defaults.set(Array(hidden), forKey: "menuBar.hidden")
    }

    /// Window id shown in the menu bar, or `highest` for whichever is most used.
    func menuBarWindow(_ p: ProviderID) -> String {
        // Cursor's API bucket often sits at 100% while the plan as a whole is fine.
        windows[p.rawValue] ?? (p == .cursor ? "total" : Self.highest)
    }

    func setMenuBarWindow(_ p: ProviderID, _ id: String) {
        windows[p.rawValue] = id
        defaults.set(windows, forKey: "menuBar.windows")
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
