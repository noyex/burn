import Foundation
import Testing
@testable import Burn

struct ThemeSpecTests {
    private func parse(_ json: String, fontExists: (String) -> Bool = { _ in true }) -> (theme: ResolvedTheme, issues: [String]) {
        ResolvedTheme.parse(Data(json.utf8), name: "file", fontExists: fontExists)
    }

    @Test func parsesHexColors() {
        #expect(RGBA("#fff") == RGBA(hex: 0xFFFFFF))
        #expect(RGBA("#D97757") == RGBA(hex: 0xD97757))
        #expect(RGBA("#00000080")?.a == 128.0 / 255)
        #expect(RGBA("D97757") == nil)
        #expect(RGBA("#GGGGGG") == nil)
        #expect(RGBA("#12345") == nil)
        #expect(RGBA(hex: 0x000000, alpha: 0.4).hex == "#00000066")
    }

    @Test func emptyThemeIsTheBuiltInLook() {
        let (theme, issues) = parse("{}")
        #expect(issues.isEmpty)
        for token in ThemeToken.allCases {
            #expect(theme.color(token, dark: false) == token.standard(dark: false))
            #expect(theme.color(token, dark: true) == token.standard(dark: true))
        }
        #expect(theme.radius == 14)
        #expect(theme.gap == 6)
        #expect(theme.textFont == nil)
    }

    @Test func appearanceOverridesSharedColors() {
        let (theme, issues) = parse(##"{"name": "T", "colors": {"base": "#111111"}, "dark": {"base": "#222222"}}"##)
        #expect(issues.isEmpty)
        #expect(theme.name == "T")
        #expect(theme.color(.base, dark: false) == RGBA(hex: 0x111111))
        #expect(theme.color(.base, dark: true) == RGBA(hex: 0x222222))
        // Untouched tokens keep the built-in value.
        #expect(theme.color(.text, dark: true) == ThemeToken.text.standard(dark: true))
    }

    @Test func derivesInkForAChangedFill() {
        let (theme, _) = parse(##"{"colors": {"coral": "#101010", "accent": "#F0F0F0", "sky": "#000000", "sky-ink": "#00FF00"}}"##)
        #expect(theme.color(.coralInk, dark: false) == RGBA(hex: 0xFFFFFF))
        #expect(theme.color(.accentInk, dark: true) == RGBA(hex: 0x141414))
        #expect(theme.color(.skyInk, dark: false) == RGBA(hex: 0x00FF00))
        // A fill the theme leaves alone keeps its designed ink.
        #expect(theme.color(.lavenderInk, dark: false) == ThemeToken.lavenderInk.standard(dark: false))
    }

    @Test func reportsWhatItSkips() {
        let (theme, issues) = parse(##"""
        {"extra": 1, "colors": {"nope": "#000000", "base": "red"},
         "shape": {"radius": 99, "gap": "wide"}, "fonts": {"text": "Missing Sans", "display": "Real"}}
        """##) { $0 == "Real" }
        #expect(issues.count == 6)
        #expect(theme.color(.base, dark: false) == ThemeToken.base.standard(dark: false))
        #expect(theme.radius == 24)
        #expect(theme.gap == 6)
        #expect(theme.textFont == nil)
        #expect(theme.displayFont == "Real")
    }

    @Test func brokenJSONFallsBackToTheBuiltInLook() {
        let (theme, issues) = parse("{ not json")
        #expect(issues.count == 1)
        #expect(theme.color(.base, dark: false) == ThemeToken.base.standard(dark: false))
    }

    @Test func displayFontFollowsTextFont() {
        let (theme, _) = parse(##"{"fonts": {"text": "Avenir Next"}}"##)
        #expect(theme.displayFont == "Avenir Next")
    }

    /// The guide in the user's themes folder is how agents learn the format: a token missing
    /// from it can't be themed in practice.
    @Test func guideDocumentsEveryToken() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let guide = try String(contentsOf: root.appendingPathComponent("docs/themes.md"), encoding: .utf8)
        for token in ThemeToken.allCases {
            let light = token.standard(dark: false)?.hex ?? "system"
            let dark = token.standard(dark: true)?.hex ?? "system"
            let row = "| `\(token.rawValue)` | `\(light)` | `\(dark)` |"
            #expect(guide.contains(row), "docs/themes.md needs the row: \(row)")
        }
    }
}
