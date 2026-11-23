import AppKit
import SwiftUI

enum ProviderIcon {
    @MainActor private static var cache: [ProviderID: NSImage] = [:]

    @MainActor
    static func image(_ p: ProviderID) -> NSImage {
        if let img = cache[p] { return img }
        let svg = switch p {
        case .claude: ProviderLogoSVG.claude
        case .codex: ProviderLogoSVG.openai
        case .cursor: ProviderLogoSVG.cursor
        case .antigravity: ProviderLogoSVG.antigravity
        }
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage()
        img.isTemplate = true
        cache[p] = img
        return img
    }
}

struct ProviderGlyph: View {
    let provider: ProviderID
    var size: CGFloat = 14
    let color: Color

    var body: some View {
        Image(nsImage: ProviderIcon.image(provider))
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
