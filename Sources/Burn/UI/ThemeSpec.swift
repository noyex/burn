import Foundation

/// An sRGB color with alpha, written in themes as `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
struct RGBA: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(hex: UInt32, alpha: Double = 1) {
        r = Double(hex >> 16 & 0xFF) / 255
        g = Double(hex >> 8 & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    init?(_ string: String) {
        var digits = Substring(string.trimmingCharacters(in: .whitespaces))
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = Substring(digits.map { "\($0)\($0)" }.joined()) }
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 8 {
            self.init(hex: UInt32(value >> 8), alpha: Double(value & 0xFF) / 255)
        } else {
            self.init(hex: UInt32(value))
        }
    }

    var hex: String {
        let parts = [r, g, b] + (a < 1 ? [a] : [])
        return "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    var isLight: Bool { luminance > 0.5 }

    /// Near-black or white, whichever reads better on this fill.
    var readableInk: RGBA {
        let dark = RGBA(hex: 0x141414)
        let onDark = (luminance + 0.05) / (dark.luminance + 0.05)
        let onWhite = 1.05 / (luminance + 0.05)
        return onDark >= onWhite ? dark : RGBA(hex: 0xFFFFFF)
    }
}

/// Every color a theme can set. The raw value is the key in theme files and the CSS variable
/// on Windows, so it is a public contract: add tokens freely, never rename or remove one.
enum ThemeToken: String, CaseIterable, Sendable {
    case base
    case neutral
    case neutralHover = "neutral-hover"
    case raised
    case text
    case secondary
    case surface
    case switcher
    case switcherInk = "switcher-ink"
    case hairline
    case shadow
    case accent
    case accentInk = "accent-ink"
    case coral
    case coralInk = "coral-ink"
    case mono
    case monoInk = "mono-ink"
    case lavender
    case lavenderInk = "lavender-ink"
    case sky
    case skyInk = "sky-ink"
    case warnOnLight = "warn-on-light"
    case fullOnLight = "full-on-light"
    case warnOnDark = "warn-on-dark"
    case fullOnDark = "full-on-dark"
    case danger
    case menuBarWarn = "menubar-warn"
    case menuBarFull = "menubar-full"
    case selection

    /// Built-in value; nil means "the system color" (menu bar alerts, the selection ring).
    func standard(dark: Bool) -> RGBA? {
        func pick(_ light: UInt32, _ darkHex: UInt32) -> RGBA { RGBA(hex: dark ? darkHex : light) }
        switch self {
        case .base: return pick(0xF7F5F2, 0x161514)
        case .neutral: return pick(0xECE9E4, 0x252321)
        case .neutralHover: return pick(0xE3DFD9, 0x302D2B)
        case .raised: return pick(0xFFFFFF, 0x3D3936)
        case .text: return pick(0x1C1A17, 0xF2EFEA)
        case .secondary: return pick(0x7A746C, 0x9C958C)
        case .surface: return pick(0xFBFAF8, 0x1F1D1B)
        case .switcher: return pick(0x1C1A17, 0x2E2B28)
        case .switcherInk: return RGBA(hex: 0xFFFFFF)
        case .hairline: return dark ? RGBA(hex: 0xFFFFFF, alpha: 0.08) : RGBA(hex: 0x000000, alpha: 0.04)
        case .shadow: return RGBA(hex: 0x000000, alpha: dark ? 0.4 : 0.16)
        case .accent: return RGBA(hex: 0xDFF26B)
        case .accentInk: return RGBA(hex: 0x1A1D06)
        case .coral: return RGBA(hex: 0xD97757)
        case .coralInk: return RGBA(hex: 0xFFFFFF)
        case .mono: return pick(0x141414, 0xF2F1EE)
        case .monoInk: return pick(0xFFFFFF, 0x141414)
        case .lavender: return RGBA(hex: 0xC9C5FF)
        case .lavenderInk: return RGBA(hex: 0x1B1840)
        case .sky: return RGBA(hex: 0xB4DDF7)
        case .skyInk: return RGBA(hex: 0x0C2C42)
        case .warnOnLight: return RGBA(hex: 0xC25E00)
        case .fullOnLight: return RGBA(hex: 0xD92D20)
        case .warnOnDark: return RGBA(hex: 0xFFB340)
        case .fullOnDark: return RGBA(hex: 0xFF6B5E)
        case .danger: return pick(0xFF3B30, 0xFF453A)
        case .menuBarWarn, .menuBarFull, .selection: return nil
        }
    }

    /// Fills whose text color is derived when a theme changes the fill but not the ink.
    static let inkPairs: [(fill: ThemeToken, ink: ThemeToken)] = [
        (.accent, .accentInk), (.switcher, .switcherInk), (.coral, .coralInk),
        (.mono, .monoInk), (.lavender, .lavenderInk), (.sky, .skyInk),
    ]
}

/// What a theme draws on a block on top of its fill color: a gradient, an image, a pattern.
struct BlockBackground: Equatable, Sendable {
    /// A color written out, or another token's color so it follows light and dark.
    enum Paint: Equatable, Sendable {
        case color(RGBA)
        case token(ThemeToken)

        init?(_ string: String) {
            if let color = RGBA(string) {
                self = .color(color)
            } else if let token = ThemeToken(rawValue: string), token.standard(dark: false) != nil {
                // Tokens that default to a system color have nothing to paint with.
                self = .token(token)
            } else {
                return nil
            }
        }
    }

    struct Gradient: Equatable, Sendable {
        var colors: [Paint]
        /// Degrees, as in CSS: 0 runs bottom to top, 90 left to right, 180 top to bottom.
        var angle = 180.0
    }

    struct Pattern: Equatable, Sendable {
        enum Kind: String, CaseIterable, Sendable { case dots, grid, lines }
        enum Fade: String, CaseIterable, Sendable { case top, bottom }

        var kind: Kind
        var color: Paint
        var opacity = 0.25
        /// Distance between marks, and how thick each one is, in points.
        var spacing = 8.0
        var size = 1.5
        /// Edge the pattern fades out toward.
        var fade: Fade?
    }

    struct Image: Equatable, Sendable {
        /// A file in the themes folder.
        var file: String
        var opacity = 1.0
    }

    var gradient: Gradient?
    var image: Image?
    var pattern: Pattern?

    /// Blocks that can carry a background, with the ink a pattern defaults to.
    static let slots: [ThemeToken: ThemeToken] = [
        .accent: .accentInk, .coral: .coralInk, .mono: .monoInk, .lavender: .lavenderInk,
        .sky: .skyInk, .neutral: .text, .surface: .text,
    ]
}

/// A theme file laid over the built-in look. Whatever the file leaves out keeps its built-in
/// value, so a theme written for an older Burn keeps working when new tokens appear.
struct ResolvedTheme: Equatable, Sendable {
    static let radiusRange = 0.0...24.0
    static let gapRange = 2.0...12.0
    static let pillRange = 0.0...999.0

    var name = "Default"
    private(set) var light: [ThemeToken: RGBA] = [:]
    private(set) var dark: [ThemeToken: RGBA] = [:]
    var radius = 14.0
    var gap = 6.0
    /// Corner radius of buttons, pills and the tab switcher; the default is fully round.
    var pill = 999.0
    private(set) var backgrounds: [ThemeToken: BlockBackground] = [:]
    /// Font family for text and for the big numbers; nil keeps Bricolage Grotesque.
    var textFont: String?
    var displayFont: String?

    static let standard = ResolvedTheme()

    func color(_ token: ThemeToken, dark isDark: Bool) -> RGBA? {
        (isDark ? dark : light)[token] ?? token.standard(dark: isDark)
    }

    /// The `name` a theme file gives itself, without resolving the rest of it.
    static func title(of data: Data) -> String? {
        let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
        return name?.isEmpty == false ? name : nil
    }

    /// Reads a theme file. Never fails: anything it can't use is skipped and reported in `issues`.
    static func parse(_ data: Data, name fallbackName: String,
                      fontExists: (String) -> Bool = { _ in true },
                      imageExists: (String) -> Bool = { _ in true }) -> (theme: ResolvedTheme, issues: [String]) {
        var theme = ResolvedTheme()
        theme.name = fallbackName
        var issues: [String] = []
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (theme, ["The file must be a JSON object."])
            }
            root = object
        } catch {
            return (theme, ["Not valid JSON: \(error.localizedDescription)"])
        }

        let known: Set = ["name", "colors", "light", "dark", "shape", "fonts", "backgrounds"]
        for key in root.keys.sorted() where !known.contains(key) { issues.append("Unknown key \"\(key)\".") }
        if let name = root["name"] as? String, !name.isEmpty { theme.name = name }

        func colors(_ section: String) -> [ThemeToken: RGBA] {
            guard let raw = root[section] else { return [:] }
            guard let entries = raw as? [String: Any] else {
                issues.append("\"\(section)\" must be an object of token: color.")
                return [:]
            }
            var result: [ThemeToken: RGBA] = [:]
            for key in entries.keys.sorted() {
                guard let token = ThemeToken(rawValue: key) else {
                    issues.append("\(section).\(key): unknown token.")
                    continue
                }
                guard let string = entries[key] as? String, let color = RGBA(string) else {
                    issues.append("\(section).\(key): not a color, use #RRGGBB or #RRGGBBAA.")
                    continue
                }
                result[token] = color
            }
            return result
        }
        let shared = colors("colors")
        theme.light = shared.merging(colors("light")) { $1 }
        theme.dark = shared.merging(colors("dark")) { $1 }
        for pair in ThemeToken.inkPairs {
            if let fill = theme.light[pair.fill], theme.light[pair.ink] == nil { theme.light[pair.ink] = fill.readableInk }
            if let fill = theme.dark[pair.fill], theme.dark[pair.ink] == nil { theme.dark[pair.ink] = fill.readableInk }
        }

        /// A number from `object`, clamped to `range`; nil when missing or not a number.
        func number(_ object: [String: Any], _ key: String, at path: String, in range: ClosedRange<Double>) -> Double? {
            guard let value = object[key] else { return nil }
            // JSON true and false bridge to numbers too; 0 and 1 must not be mistaken for them.
            guard let boxed = value as? NSNumber, CFGetTypeID(boxed) != CFBooleanGetTypeID() else {
                issues.append("\(path).\(key): must be a number.")
                return nil
            }
            let number = boxed.doubleValue
            if !range.contains(number) {
                issues.append("\(path).\(key): \(Self.short(number)) is outside \(Self.short(range.lowerBound))–\(Self.short(range.upperBound)), clamped.")
            }
            return min(max(number, range.lowerBound), range.upperBound)
        }
        func unknownKeys(_ object: [String: Any], at path: String, known: Set<String>) {
            for key in object.keys.sorted() where !known.contains(key) { issues.append("\(path).\(key): unknown key.") }
        }
        func paint(_ object: [String: Any], _ key: String, at path: String) -> BlockBackground.Paint? {
            guard let value = object[key] else { return nil }
            guard let string = value as? String, let paint = BlockBackground.Paint(string) else {
                issues.append("\(path).\(key): use #RRGGBB, #RRGGBBAA or a token name.")
                return nil
            }
            return paint
        }

        if let raw = root["shape"] {
            if let shape = raw as? [String: Any] {
                unknownKeys(shape, at: "shape", known: ["radius", "gap", "pill"])
                theme.radius = number(shape, "radius", at: "shape", in: radiusRange) ?? theme.radius
                theme.gap = number(shape, "gap", at: "shape", in: gapRange) ?? theme.gap
                theme.pill = number(shape, "pill", at: "shape", in: pillRange) ?? theme.pill
            } else {
                issues.append("\"shape\" must be an object.")
            }
        }

        if let raw = root["fonts"] {
            if let fonts = raw as? [String: Any] {
                func family(_ key: String) -> String? {
                    guard let value = fonts[key] else { return nil }
                    guard let name = value as? String, !name.isEmpty else {
                        issues.append("fonts.\(key): must be a font family name.")
                        return nil
                    }
                    guard fontExists(name) else {
                        issues.append("fonts.\(key): \"\(name)\" is not installed on this computer.")
                        return nil
                    }
                    return name
                }
                for key in fonts.keys.sorted() where key != "text" && key != "display" { issues.append("fonts.\(key): unknown key.") }
                theme.textFont = family("text")
                theme.displayFont = family("display") ?? theme.textFont
            } else {
                issues.append("\"fonts\" must be an object.")
            }
        }

        if let raw = root["backgrounds"] {
            if let blocks = raw as? [String: Any] {
                for key in blocks.keys.sorted() {
                    let path = "backgrounds.\(key)"
                    guard let slot = ThemeToken(rawValue: key), let ink = BlockBackground.slots[slot] else {
                        issues.append("\(path): not a block. Use one of \(BlockBackground.slots.keys.map(\.rawValue).sorted().joined(separator: ", ")).")
                        continue
                    }
                    guard let block = blocks[key] as? [String: Any] else {
                        issues.append("\(path): must be an object.")
                        continue
                    }
                    unknownKeys(block, at: path, known: ["gradient", "image", "pattern"])
                    var background = BlockBackground()

                    if let gradient = block["gradient"] as? [String: Any] {
                        unknownKeys(gradient, at: "\(path).gradient", known: ["colors", "angle"])
                        let colors = (gradient["colors"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(BlockBackground.Paint.init) }
                        if colors.count >= 2, colors.count == (gradient["colors"] as? [Any])?.count {
                            background.gradient = .init(colors: colors)
                            if let angle = number(gradient, "angle", at: "\(path).gradient", in: -360...360) { background.gradient?.angle = angle }
                        } else {
                            issues.append("\(path).gradient.colors: needs two or more colors (#RRGGBB or token names).")
                        }
                    } else if block["gradient"] != nil {
                        issues.append("\(path).gradient: must be an object.")
                    }

                    if let image = block["image"] as? [String: Any] {
                        unknownKeys(image, at: "\(path).image", known: ["file", "opacity"])
                        if let file = image["file"] as? String, !file.isEmpty, !file.contains("/"), !file.hasPrefix(".") {
                            if imageExists(file) {
                                background.image = .init(file: file)
                                if let opacity = number(image, "opacity", at: "\(path).image", in: 0...1) { background.image?.opacity = opacity }
                            } else {
                                issues.append("\(path).image.file: \"\(file)\" isn't in the themes folder.")
                            }
                        } else {
                            issues.append("\(path).image.file: must be the name of a file in the themes folder.")
                        }
                    } else if block["image"] != nil {
                        issues.append("\(path).image: must be an object.")
                    }

                    if let pattern = block["pattern"] as? [String: Any] {
                        let at = "\(path).pattern"
                        unknownKeys(pattern, at: at, known: ["type", "color", "opacity", "spacing", "size", "fade"])
                        if let kind = (pattern["type"] as? String).flatMap(BlockBackground.Pattern.Kind.init) {
                            var result = BlockBackground.Pattern(kind: kind, color: paint(pattern, "color", at: at) ?? .token(ink))
                            result.opacity = number(pattern, "opacity", at: at, in: 0...1) ?? result.opacity
                            result.spacing = number(pattern, "spacing", at: at, in: 3...64) ?? result.spacing
                            result.size = number(pattern, "size", at: at, in: 0.5...16) ?? result.size
                            if let fade = pattern["fade"] {
                                result.fade = (fade as? String).flatMap(BlockBackground.Pattern.Fade.init)
                                if result.fade == nil { issues.append("\(at).fade: use \"top\" or \"bottom\".") }
                            }
                            background.pattern = result
                        } else {
                            issues.append("\(at).type: use \"dots\", \"grid\" or \"lines\".")
                        }
                    } else if block["pattern"] != nil {
                        issues.append("\(path).pattern: must be an object.")
                    }

                    if background != BlockBackground() { theme.backgrounds[slot] = background }
                }
            } else {
                issues.append("\"backgrounds\" must be an object.")
            }
        }
        return (theme, issues)
    }

    private static func short(_ value: Double) -> String {
        // %g never traps, however large the number in the file is.
        String(format: "%g", value)
    }
}
