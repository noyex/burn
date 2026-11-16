import SwiftUI

/// The theme's gradient, image and pattern for a block, drawn over its fill color.
struct BlockDecoration: View {
    let background: BlockBackground
    let theme: Theme

    var body: some View {
        ZStack {
            if let gradient = background.gradient {
                let radians = gradient.angle * .pi / 180
                let dx = sin(radians) / 2, dy = -cos(radians) / 2
                LinearGradient(colors: gradient.colors.map(theme.paint),
                               startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                               endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
            }
            if let image = background.image, let picture = ThemeStore.shared.image(image.file) {
                // The overlay keeps a large picture from stretching the block.
                Color.clear
                    .overlay { Image(nsImage: picture).resizable().scaledToFill() }
                    .clipped()
                    .opacity(image.opacity)
            }
            if let pattern = background.pattern {
                PatternCanvas(pattern: pattern, color: theme.paint(pattern.color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PatternCanvas: View {
    let pattern: BlockBackground.Pattern
    let color: Color

    var body: some View {
        Canvas { context, size in
            let step = pattern.spacing
            let mark = pattern.size
            var path = Path()
            switch pattern.kind {
            case .dots:
                for x in stride(from: step / 2, to: size.width, by: step) {
                    for y in stride(from: step / 2, to: size.height, by: step) {
                        path.addEllipse(in: CGRect(x: x - mark / 2, y: y - mark / 2, width: mark, height: mark))
                    }
                }
                context.fill(path, with: .color(color))
            case .grid:
                for x in stride(from: step / 2, to: size.width, by: step) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: step / 2, to: size.height, by: step) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(color), lineWidth: mark)
            case .lines:
                for x in stride(from: -size.height, to: size.width, by: step) {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                context.stroke(path, with: .color(color), lineWidth: mark)
            case .wave, .level, .halftone, .rain:
                // Drawn by the animated renderer.
                break
            }
        }
        .opacity(pattern.opacity)
        .mask {
            switch pattern.fade {
            case .top: LinearGradient(colors: [.clear, Theme.mask], startPoint: .top, endPoint: .bottom)
            case .bottom: LinearGradient(colors: [Theme.mask, .clear], startPoint: .top, endPoint: .bottom)
            case nil: Theme.mask
            }
        }
    }
}
