import AppKit
import CoreText
import SwiftUI

/// Colors of the bento look: a warm base, neutral blocks, and one solid block per provider.
struct Theme {
    let scheme: ColorScheme

    init(_ scheme: ColorScheme) { self.scheme = scheme }

    private var dark: Bool { scheme == .dark }

    var base: Color { dark ? Color(hex: 0x161514) : Color(hex: 0xF7F5F2) }
    var neutral: Color { dark ? Color(hex: 0x252321) : Color(hex: 0xECE9E4) }
    var neutralHover: Color { dark ? Color(hex: 0x302D2B) : Color(hex: 0xE3DFD9) }
    /// Selected pill on a neutral track.
    var raised: Color { dark ? Color(hex: 0x3D3936) : .white }
    var text: Color { dark ? Color(hex: 0xF2EFEA) : Color(hex: 0x1C1A17) }
    var secondary: Color { dark ? Color(hex: 0x9C958C) : Color(hex: 0x7A746C) }
    /// Standalone chrome floating over the desktop: the footer, settings, the expand button.
    var surface: Color { dark ? Color(hex: 0x1F1D1B) : Color(hex: 0xFBFAF8) }
    /// The dark tab switcher capsule, in both appearances.
    var switcher: Color { dark ? Color(hex: 0x2E2B28) : Color(hex: 0x1C1A17) }
    /// Edge that keeps dark blocks apart from a dark desktop.
    var hairline: Color { dark ? .white.opacity(0.08) : .black.opacity(0.04) }
    var shadow: Color { .black.opacity(dark ? 0.4 : 0.16) }

    static let lime = Color(hex: 0xDFF26B)
    static let limeInk = Color(hex: 0x1A1D06)

    func fill(_ p: ProviderID) -> Color { fill(p.brandColor) }
    func ink(_ p: ProviderID) -> Color { ink(p.brandColor) }

    func fill(_ c: CardColor) -> Color {
        switch c {
        case .coral: Color(hex: 0xD97757)
        case .mono: dark ? Color(hex: 0xF2F1EE) : Color(hex: 0x141414)
        case .lavender: Color(hex: 0xC9C5FF)
        case .sky: Color(hex: 0xB4DDF7)
        }
    }

    func ink(_ c: CardColor) -> Color {
        switch c {
        case .coral: .white
        case .mono: dark ? Color(hex: 0x141414) : .white
        case .lavender: Color(hex: 0x1B1840)
        case .sky: Color(hex: 0x0C2C42)
        }
    }

    /// Alert text inside a pill filled with the block's ink, readable on light and dark ink alike.
    func alert(_ level: MenuBarImage.Level, on c: CardColor) -> Color {
        let lightInk = switch c {
        case .coral: true
        case .mono: !dark
        case .lavender, .sky: false
        }
        switch level {
        case .normal: return ink(c)
        case .warn: return lightInk ? Color(hex: 0xC25E00) : Color(hex: 0xFFB340)
        case .full: return lightInk ? Color(hex: 0xD92D20) : Color(hex: 0xFF6B5E)
        }
    }

    /// Popover background as an appearance-aware AppKit color, for the preview window.
    static let baseNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x16 / 255, green: 0x15 / 255, blue: 0x14 / 255, alpha: 1)
            : NSColor(srgbRed: 0xF7 / 255, green: 0xF5 / 255, blue: 0xF2 / 255, alpha: 1)
    }
}

/// Fill a provider card can take: the three brand colors and one extra.
enum CardColor: String, CaseIterable, Identifiable {
    case coral, mono, lavender, sky

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Fonts

/// Bricolage Grotesque, bundled in Burn.app/Contents/Resources/Fonts. Falls back to SF Pro
/// when the fonts aren't there (e.g. a bare `swift run`).
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
        BrandFont.isAvailable ? .custom(font.postScriptName, fixedSize: size)
            : .system(size: size, weight: font.fallbackWeight)
    }
}
