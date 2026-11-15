import AppKit
import CoreServices
import ImageIO
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
        /// Ships inside the app rather than living in the user's folder.
        var builtIn = false
        /// The parsed theme, for its preview in Settings.
        var look = ResolvedTheme.standard
    }

    /// Ready-made themes inside the app. A file of the same name in the user's folder wins.
    nonisolated static let builtInDirectory = Bundle.main.resourceURL?.appendingPathComponent("Themes", isDirectory: true)

    /// The file a theme name stands for: the user's own, else the built-in one.
    nonisolated static func file(for name: String) -> URL {
        let own = directory.appendingPathComponent(name + ".json")
        if !FileManager.default.fileExists(atPath: own.path),
           let builtIn = builtInDirectory?.appendingPathComponent(name + ".json"),
           FileManager.default.fileExists(atPath: builtIn.path) { return builtIn }
        return own
    }

    private(set) var available: [Entry] = []
    /// Name in `active.txt`; nil is the built-in look.
    private(set) var selected: String?
    /// What's wrong with the selected theme, for Settings.
    private(set) var issues: [String] = []

    /// The menu bar is drawn outside SwiftUI and has to be told.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var stream: FSEventStreamRef?
    /// Pictures by file name; nil for one that couldn't be read, so it isn't retried on every draw.
    @ObservationIgnored private var images: [String: NSImage?] = [:]
    /// Bumped when the pictures may have changed on disk, so blocks showing one redraw.
    private var imageVersion = 0

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

    /// A background picture from the themes folder.
    func image(_ file: String) -> NSImage? {
        _ = imageVersion
        if let cached = images[file] { return cached }
        let loaded = Self.picture(at: Self.directory.appendingPathComponent(file))
        images.updateValue(loaded, forKey: file)
        return loaded
    }

    /// Name of the theme in use, for Settings.
    var selectedTitle: String {
        guard let selected else { return "Default" }
        return available.first { $0.id == selected }?.title ?? selected
    }

    /// Scaled down on load: a block is never wider than the panel, and the share card at 2x needs
    /// 1200 px. Only plain files up to 25 MB, so a huge photo or a symlink to a device can't stall
    /// the main thread.
    private static func picture(at url: URL) -> NSImage? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 25_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func openFolder() {
        NSWorkspace.shared.open(Self.directory)
    }

    /// What a user pastes to their coding agent to have a theme made.
    static var agentPrompt: String {
        "Make me a theme for Burn, my menu bar app. First read \"\(guideFile.path)\": it explains the "
            + "format, how to turn the theme on and how to check it. What I want: "
    }

    /// For a user with no idea yet: the agent comes up with a few designs to pick from.
    static var ideasPrompt: String {
        "Design 4 themes for Burn, my menu bar app, each in a clearly different style. First read "
            + "\"\(guideFile.path)\": it explains the format and how to check a theme. Write each one as a new "
            + "file in the themes folder, never over an existing one. Use colors, block backgrounds, shape and "
            + "fonts, and check every file. "
            + "Then describe each theme in one line and turn on the one you like best. I'll try the rest in "
            + "Burn → Settings → Theme."
    }

    /// `families` saves asking AppKit for the font list once per file when loading many.
    static func loadFile(_ url: URL, families: Set<String>? = nil) -> (theme: ResolvedTheme, issues: [String])? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let families = families ?? Set(NSFontManager.shared.availableFontFamilies)
        return ResolvedTheme.parse(data, name: url.deletingPathExtension().lastPathComponent,
                                   fontExists: { families.contains($0) || NSFont(name: $0, size: 12) != nil },
                                   imageExists: { FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent($0).path) })
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let families = Set(NSFontManager.shared.availableFontFamilies)
        func list(_ urls: [URL], builtIn: Bool) -> [Entry] {
            urls.filter { $0.pathExtension == "json" }
                .map { url -> Entry in
                    let id = url.deletingPathExtension().lastPathComponent
                    let look = Self.loadFile(url, families: families)?.theme
                    return Entry(id: id, title: look?.name ?? id, builtIn: builtIn, look: look ?? .standard)
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let own = list(files, builtIn: false)
        let shipped = Self.builtInDirectory.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        let entries = list(shipped, builtIn: true).filter { theme in
            !own.contains { $0.id.caseInsensitiveCompare(theme.id) == .orderedSame }
        } + own
        var name = (try? String(contentsOf: Self.activeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.hasSuffix(".json") == true { name = name.map { String($0.dropLast(5)) } }
        if name == "" { name = nil }
        // The file system ignores case; show the name the way the file spells it.
        if let match = entries.first(where: { $0.id.caseInsensitiveCompare(name ?? "") == .orderedSame }) { name = match.id }

        var next = ResolvedTheme.standard
        var problems: [String] = []
        if let name {
            // A name, never a path out of the themes folder.
            if name.contains("/") || name.hasPrefix(".") {
                problems = ["active.txt must hold a theme's file name, not a path."]
            } else if let loaded = Self.loadFile(Self.file(for: name), families: families) {
                (next, problems) = loaded
            } else {
                problems = ["Theme \"\(name)\" isn't in the themes folder."]
            }
        }
        if available != entries { available = entries }
        if selected != name { selected = name }
        if issues != problems { issues = problems }
        // A picture can change under the same name.
        if !images.isEmpty {
            images = [:]
            imageVersion += 1
        }
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
    var url = argument.contains("/") || argument.hasSuffix(".json")
        ? URL(fileURLWithPath: argument)
        : ThemeStore.file(for: argument)
    // `midnight.json` is a file here, or else the theme of that name, as in `active.txt`.
    if !argument.contains("/"), argument.hasSuffix(".json"), !FileManager.default.fileExists(atPath: url.path) {
        url = ThemeStore.file(for: String(argument.dropLast(5)))
    }
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
