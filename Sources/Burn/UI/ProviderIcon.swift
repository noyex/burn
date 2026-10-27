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
        }
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage()
        img.isTemplate = true
        cache[p] = img
        return img
    }
}

extension ProviderID {
    /// Brand tint for bars and chart; nil means "use the primary label color".
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex: Color.primary.opacity(0.8)
        case .cursor: Color(red: 0.647, green: 0.690, blue: 1.0)
        }
    }

    var iconTint: Color {
        self == .claude ? tint : .primary
    }
}

struct ProviderGlyph: View {
    let provider: ProviderID
    var size: CGFloat = 14
    var color: Color?

    var body: some View {
        Image(nsImage: ProviderIcon.image(provider))
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(color ?? provider.iconTint)
            .accessibilityHidden(true)
    }
}
