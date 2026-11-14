import AppKit
import CoreServices
import Observation
import SwiftUI

/// Loads the user's theme from the themes folder and reloads it as files change.
///
/// Everything a user or their agent touches lives in that one folder, outside the app bundle,
/// so an update never overwrites it: `<name>.json` themes, `active.txt` naming the one in use,
/// and `README.md`, the guide Burn rewrites on launch.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    nonisolated static let directory = URL(fileURLWithPath: UsageStore.supportDir + "/themes", isDirectory: true)
    private nonisolated static let activeFile = directory.appendingPathComponent("active.txt")
    private nonisolated static let guideFile = directory.appendingPathComponent("README.md")

    private(set) var theme = ResolvedTheme.standard
    struct Entry: Equatable, Identifiable {
        /// File name without `.json`; what `active.txt` holds.
        let id: String
        /// The theme's own `name`, or the file name.
        let title: String
    }

    private(set) var available: [Entry] = []
    /// Name in `active.txt`; nil is the built-in look.
    private(set) var selected: String?
    /// What's wrong with the selected theme, for Settings.
    private(set) var issues: [String] = []

    /// The menu bar is drawn outside SwiftUI and has to be told.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var stream: FSEventStreamRef?

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        writeGuide()
        reload()
        watch()
    }

    func select(_ name: String?) {
        try? Data((name ?? "").utf8).write(to: Self.activeFile, options: .atomic)
        reload()
    }

    func openFolder() {
        NSWorkspace.shared.open(Self.directory)
    }

    /// What a user pastes to their coding agent to have a theme made.
    static var agentPrompt: String {
        "Make me a theme for Burn, my menu bar app. First read \"\(guideFile.path)\": it explains the "
            + "format, how to turn the theme on and how to check it. What I want: "
    }

    static func loadFile(_ url: URL) -> (theme: ResolvedTheme, issues: [String])? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ResolvedTheme.parse(data, name: url.deletingPathExtension().lastPathComponent, fontExists: fontExists)
    }

    private static func fontExists(_ name: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(name) || NSFont(name: name, size: 12) != nil
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let entries = files.filter { $0.pathExtension == "json" }
            .map { url -> Entry in
                let id = url.deletingPathExtension().lastPathComponent
                return Entry(id: id, title: Self.loadFile(url)?.theme.name ?? id)
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        var name = (try? String(contentsOf: Self.activeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.hasSuffix(".json") == true { name = name.map { String($0.dropLast(5)) } }
        if name == "" || name?.lowercased() == "default" { name = nil }

        var next = ResolvedTheme.standard
        var problems: [String] = []
        if let name {
            if let loaded = Self.loadFile(Self.directory.appendingPathComponent(name + ".json")) {
                (next, problems) = loaded
            } else {
                problems = ["Theme \"\(name)\" isn't in the themes folder."]
            }
        }
        if available != entries { available = entries }
        if selected != name { selected = name }
        if issues != problems { issues = problems }
        guard next != theme else { return }
        withAnimation(.easeOut(duration: 0.2)) { theme = next }
        onChange?()
    }

    /// The guide ships in the app, so it always describes the tokens of the version installed.
    private func writeGuide() {
        guard let source = Bundle.main.url(forResource: "themes", withExtension: "md"),
              let guide = try? Data(contentsOf: source) else { return }
        let note = "<!-- Burn rewrites this file on every launch. Your themes are the .json files next to it. -->\n\n"
        let data = Data(note.utf8) + guide
        if (try? Data(contentsOf: Self.guideFile)) != data { try? data.write(to: Self.guideFile, options: .atomic) }
    }

    private func watch() {
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            // Scheduled on the main queue below.
            MainActor.assumeIsolated { ThemeStore.shared.reload() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, nil, [Self.directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}

/// `Burn --check-theme <name or path>`: prints what's wrong with a theme, for agents writing one.
@MainActor
func runCheckTheme(_ argument: String?) -> Int32 {
    guard let argument else {
        print("Usage: Burn --check-theme <theme name or path to .json>")
        return 2
    }
    let url = argument.contains("/") || argument.hasSuffix(".json")
        ? URL(fileURLWithPath: argument)
        : ThemeStore.directory.appendingPathComponent(argument + ".json")
    guard let (theme, issues) = ThemeStore.loadFile(url) else {
        print("Can't read \(url.path)")
        return 2
    }
    if issues.isEmpty {
        print("OK: \"\(theme.name)\" has no problems.")
        return 0
    }
    print("\"\(theme.name)\" has \(issues.count) problem\(issues.count == 1 ? "" : "s"):")
    for issue in issues { print("- \(issue)") }
    return 1
}
