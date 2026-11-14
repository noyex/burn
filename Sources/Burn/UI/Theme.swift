import AppKit
import CoreText
import SwiftUI

/// Colors of the bento look: a warm base, neutral blocks, and one solid block per provider.
/// Every value comes from the active theme (`ThemeStore`), which lays the user's file over the
/// built-in defaults in `ThemeToken`. Views never write a color literal: add a token instead.
@MainActor
struct Theme {
    let scheme: ColorScheme

    init(_ scheme: ColorScheme) { self.scheme = scheme }

    private var dark: Bool { scheme == .dark }

    private func rgba(_ token: ThemeToken) -> RGBA {
        ThemeStore.shared.theme.color(token, dark: dark) ?? RGBA(hex: 0x808080)
    }

    func color(_ token: ThemeToken) -> Color { Color(rgba(token)) }

    func paint(_ paint: BlockBackground.Paint) -> Color {
        switch paint {
        case let .color(rgba): Color(rgba)
        case let .token(token): color(token)
        }
    }

    /// What the theme draws on blocks filled with `slot`, if anything.
    func background(_ slot: ThemeToken) -> BlockBackground? { ThemeStore.shared.theme.backgrounds[slot] }

    var base: Color { color(.base) }
    var neutral: Color { color(.neutral) }
    var neutralHover: Color { color(.neutralHover) }
    /// Selected pill on a neutral track.
    var raised: Color { color(.raised) }
    var text: Color { color(.text) }
    var secondary: Color { color(.secondary) }
    /// Standalone chrome floating over the desktop: the footer, settings, the expand button.
    var surface: Color { color(.surface) }
    /// The tab switcher capsule and the icons on it.
    var switcher: Color { color(.switcher) }
    var switcherInk: Color { color(.switcherInk) }
    /// Edge that keeps dark blocks apart from a dark desktop.
    var hairline: Color { color(.hairline) }
    var shadow: Color { color(.shadow) }
    /// The spend block and other highlights.
    var accent: Color { color(.accent) }
    var accentInk: Color { color(.accentInk) }
    /// Destructive actions.
    var danger: Color { color(.danger) }

    func fill(_ p: ProviderID) -> Color { fill(p.brandColor) }
    func ink(_ p: ProviderID) -> Color { ink(p.brandColor) }

    func fill(_ c: CardColor) -> Color { color(c.tokens.fill) }
    func ink(_ c: CardColor) -> Color { color(c.tokens.ink) }

    /// Alert text inside a pill filled with the block's ink, readable on light and dark ink alike.
    func alert(_ level: MenuBarImage.Level, on c: CardColor) -> Color {
        let lightInk = rgba(c.tokens.ink).isLight
        switch level {
        case .normal: return ink(c)
        case .warn: return color(lightInk ? .warnOnLight : .warnOnDark)
        case .full: return color(lightInk ? .fullOnLight : .fullOnDark)
        }
    }

    /// Color of a menu bar entry, for the menu bar's own appearance. System colors unless the theme sets one.
    static func menuBar(_ level: MenuBarImage.Level, dark: Bool) -> NSColor {
        func themed(_ token: ThemeToken) -> NSColor? { ThemeStore.shared.theme.color(token, dark: dark).map(NSColor.init) }
        switch level {
        case .normal: return .labelColor
        case .warn: return themed(.menuBarWarn) ?? .systemOrange
        case .full: return themed(.menuBarFull) ?? .systemRed
        }
    }

    /// Popover background as an appearance-aware AppKit color, for the preview window.
    static let baseNSColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return MainActor.assumeIsolated {
            NSColor(ThemeStore.shared.theme.color(.base, dark: dark) ?? RGBA(hex: 0x808080))
        }
    }

    // Marks drawn over screenshots. They have to read on any image, so themes don't set them.
    static let photoEdge = Color.white.opacity(0.12)
    static let photoScrim = Color.black.opacity(0.25)
    static let photoShadow = Color.black.opacity(0.3)
    static let onPhoto = Color.white
    /// Opaque side of a fade mask; only its alpha matters.
    static let mask = Color.black
    /// Nearly invisible fill that still catches clicks.
    static let hitArea = Color.black.opacity(0.001)
}

/// Fill a provider card can take: the three brand colors and one extra.
enum CardColor: String, CaseIterable, Identifiable {
    case coral, mono, lavender, sky

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var tokens: (fill: ThemeToken, ink: ThemeToken) {
        switch self {
        case .coral: (.coral, .coralInk)
        case .mono: (.mono, .monoInk)
        case .lavender: (.lavender, .lavenderInk)
        case .sky: (.sky, .skyInk)
        }
    }
}

extension ProviderID {
    var brandColor: CardColor {
        switch self {
        case .claude: .coral
        case .codex: .mono
        case .cursor: .lavender
        }
    }
}

extension Color {
    init(_ c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

extension NSColor {
    convenience init(_ c: RGBA) { self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
}

// MARK: - Fonts

/// Bricolage Grotesque, bundled in Burn.app/Contents/Resources/Fonts, unless the theme names
/// another family. Falls back to SF Pro when the fonts aren't there (e.g. a bare `swift run`).
enum BrandFont {
    case medium, bold, display

    fileprivate var postScriptName: String {
        switch self {
        case .medium: "BricolageGrotesque12pt-Medium"
        case .bold: "BricolageGrotesque12pt-Bold"
        case .display: "BricolageGrotesque96pt-ExtraBold"
        }
    }

    fileprivate var fallbackWeight: Font.Weight {
        switch self {
        case .medium: .medium
        case .bold: .bold
        case .display: .heavy
        }
    }

    @MainActor private static var available = false

    @MainActor
    static func register() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                  .filter({ $0.pathExtension == "ttf" }),
              !urls.isEmpty else { return }
        // No handler: blocks until the fonts are registered.
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        available = NSFont(name: BrandFont.display.postScriptName, size: 12) != nil
    }

    @MainActor
    fileprivate static var isAvailable: Bool { available }
}

extension Font {
    @MainActor
    static func brand(_ size: CGFloat, _ font: BrandFont = .medium) -> Font {
        let theme = ThemeStore.shared.theme
        if let family = font == .display ? theme.displayFont : theme.textFont {
            return .custom(family, fixedSize: size).weight(font.fallbackWeight)
        }
        return BrandFont.isAvailable ? .custom(font.postScriptName, fixedSize: size)
            : .system(size: size, weight: font.fallbackWeight)
    }
}
