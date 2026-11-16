import SwiftUI

/// The theme's gradient, image and pattern for a block, drawn over its fill color.
struct BlockDecoration: View {
    let background: BlockBackground
    let theme: Theme
    /// Offsets the animation, so blocks don't move in lockstep.
    var seed = 0.0

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
                PatternCanvas(pattern: pattern, color: theme.paint(pattern.color),
                              highlight: pattern.highlight.map(theme.paint), seed: seed)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// False while the panel is closed and in the share image: animated patterns hold a still frame.
    @Entry var patternsMoving = true
    /// What's left of the block's limit, 0...1, for the `level` pattern; nil fills halfway.
    @Entry var blockLevel: Double?
}

enum PatternSeed {
    /// A stable, distinct offset per block token.
    static func of(_ slot: ThemeToken) -> Double {
        Double(slot.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }) * 0.37
    }
}

private struct PatternCanvas: View {
    let pattern: BlockBackground.Pattern
    let color: Color
    let highlight: Color?
    let seed: Double

    @Environment(\.patternsMoving) private var moving
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.blockLevel) private var level

    var body: some View {
        Group {
            if pattern.kind.isAnimated {
                // Paused (not removed) when still, so a frame stays on screen. ImageRenderer
                // doesn't run timelines, so the share image gets the first frame.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving || reduceMotion)) { timeline in
                    let time = moving && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 6
                    canvas(time: time)
                }
            } else {
                canvas(time: 0)
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

    private func canvas(time: Double) -> some View {
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
                let scene = AnimatedPattern(context: context, size: size, time: time, seed: seed,
                                            spacing: step, mark: mark,
                                            color: color, highlight: highlight ?? color)
                switch pattern.kind {
                case .wave: scene.wave()
                case .level: scene.level(fraction: level ?? 0.5)
                case .halftone: scene.halftone()
                default: scene.rain()
                }
            }
        }
    }
}

/// Dots collected into one path per alpha step, so a frame costs a handful of fills.
private struct DotBuckets {
    private var paths: [Path]
    private let steps: Int

    init(steps: Int = 16) {
        self.steps = steps
        paths = Array(repeating: Path(), count: steps)
    }

    /// `alpha` in 0...1 is rounded up to the nearest step.
    mutating func dot(_ x: Double, _ y: Double, radius: Double, alpha: Double) {
        guard alpha > 0.01, radius > 0 else { return }
        let step = min(steps - 1, max(0, Int((alpha * Double(steps)).rounded(.up)) - 1))
        paths[step].addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    func fill(_ context: GraphicsContext, _ color: Color) {
        for (i, path) in paths.enumerated() where !path.isEmpty {
            context.fill(path, with: .color(color.opacity(Double(i + 1) / Double(steps))))
        }
    }
}

/// One frame of the animated patterns, ported from the design mockups.
private struct AnimatedPattern {
    let context: GraphicsContext
    let size: CGSize
    let time: Double
    let seed: Double
    let spacing: Double
    let mark: Double
    let color: Color
    let highlight: Color

    private var w: Double { size.width }
    private var h: Double { size.height }

    private func fract(_ v: Double) -> Double { v - v.rounded(.down) }
    private func hash(_ n: Double) -> Double { fract(sin(n * 127.1) * 43758.5453) }
    private func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
        let u = min(1, max(0, (v - a) / (b - a)))
        return u * u * (3 - 2 * u)
    }

    /// Rows of dots in perspective over the lower part, rolling like a sea; crests in the highlight.
    func wave() {
        let rows = 14, top = 0.42
        var crests = DotBuckets(steps: 4)
        for r in 0..<rows {
            let p = Double(r) / Double(rows - 1)
            let y0 = h * top + p * p * h * (1 - top) * 1.02
            // 0.6x at the back, 1x in the middle, 1.6x at the front.
            let spread = p < 0.5 ? 0.6 + 0.8 * p : 1 + 1.2 * (p - 0.5)
            let sp = spacing * spread
            let radius = mark / 2 * (0.4 + 1.2 * p)
            let amp = 2 + p * 10
            let n = Int((w / sp / 2).rounded(.up)) + 1
            var layer = Path()
            for c in -n...n {
                let col = Double(c)
                let hgt = sin(col * 0.33 + time * 1.05 + Double(r) * 0.42 + seed) * cos(Double(r) * 0.28 - time * 0.55 + col * 0.05)
                let px = w / 2 + col * sp, py = y0 - hgt * amp
                layer.addEllipse(in: CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2))
                if p > 0.2, p < 0.85, hgt > 0.7 {
                    let glow = smooth(0.7, 0.95, hgt)
                    crests.dot(px, py, radius: radius + glow * mark * 0.33, alpha: glow)
                }
            }
            context.fill(layer, with: .color(color.opacity(0.06 + p * 0.75)))
        }
        crests.fill(context, highlight)
    }

    /// Dots filling the block up to `fraction`, under a surface that gently moves.
    func level(fraction: Double) {
        let lvl = h * (1 - min(max(fraction, 0), 1) * 0.92)
        let sp = spacing
        func surface(_ x: Double) -> Double {
            lvl + sin(x * 0.045 + time * 1.6 + seed) * 2.2 + sin(x * 0.02 - time * 0.9) * 1.6
        }
        var tint = Path()
        tint.move(to: CGPoint(x: 0, y: h))
        for x in stride(from: 0.0, through: w, by: 4) { tint.addLine(to: CGPoint(x: x, y: surface(x))) }
        tint.addLine(to: CGPoint(x: w, y: h))
        context.fill(tint, with: .color(color.opacity(0.1)))

        var below = DotBuckets(), top = Path()
        let topRadius = mark * 0.7
        for x in stride(from: sp / 2, to: w, by: sp) {
            let sy = surface(x)
            top.addEllipse(in: CGRect(x: x - topRadius, y: sy - topRadius, width: topRadius * 2, height: topRadius * 2))
            for y in stride(from: sy + sp, to: h, by: sp) {
                below.dot(x, y, radius: mark / 2, alpha: 0.22 * (1 - (y - sy) / (h - lvl + 20)) / 0.95)
            }
        }
        below.fill(context, color)
        context.fill(top, with: .color(highlight.opacity(0.95)))
    }

    /// A dot grid whose dots swell and shrink in slowly drifting patches.
    func halftone() {
        let sp = spacing
        var dots = DotBuckets()
        for x in stride(from: sp / 2, to: w, by: sp) {
            for y in stride(from: sp / 2, to: h, by: sp) {
                let n = (sin(x * 0.04 + time * 0.7 + seed) + sin(y * 0.06 - time * 0.5) + sin((x + y) * 0.025 + time * 0.35)) / 3
                let v = max(0, n * 0.5 + 0.5)
                dots.dot(x, y, radius: mark / 2 * (0.115 + 0.885 * v * v), alpha: (0.15 + v * 0.6) * y / h / 0.75)
            }
        }
        dots.fill(context, color)
    }

    /// Drops of dots falling down columns with a fading trail; the head in the highlight.
    func rain() {
        let sp = spacing
        var trail = DotBuckets(), heads = Path()
        let radius = mark / 2
        var col = 0.0
        for x in stride(from: sp / 2, to: w, by: sp) {
            let s = seed + col
            col += 1
            let speed = 0.18 + hash(s) * 0.3
            let head = fract(time * speed + hash(s + 1)) * (h + 60) - 20
            let length = 6 + (hash(s + 2) * 8).rounded(.down)
            for y in stride(from: sp / 2, to: h, by: sp) {
                let d = (head - y) / sp
                if d >= 0, d < 1 {
                    let r = radius * 1.75
                    heads.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                } else {
                    let a = d > 0 && d < length ? max(0.05, (1 - d / length) * 0.85) : 0.05
                    trail.dot(x, y, radius: radius, alpha: a)
                }
            }
        }
        trail.fill(context, color)
        context.fill(heads, with: .color(highlight.opacity(0.9)))
    }
}
