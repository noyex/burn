// Draws the DMG window background (660x400 pt) as background.png and background@2x.png.
//   swift scripts/dmg-background.swift <output-dir>
// Icon positions in package.sh must match the layout here: Burn at (180, 196), Applications at (480, 196).
import AppKit

let size = CGSize(width: 660, height: 400)
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../assets/Fonts")

func font(_ file: String, _ size: CGFloat) -> NSFont {
    let url = fonts.appendingPathComponent(file) as CFURL
    guard let desc = (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor])?.first else {
        fatalError("Missing font \(file)")
    }
    return CTFontCreateWithFontDescriptor(desc, size, nil) as NSFont
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let orange = color(0xF04E14)

func draw(in ctx: CGContext) {
    color(0xF7F5F2).setFill()
    ctx.fill(CGRect(origin: .zero, size: size))

    // Soft ember glow rising from the bottom edge.
    ctx.saveGState()
    ctx.translateBy(x: size.width / 2, y: size.height + 40)
    ctx.scaleBy(x: 600 / 260, y: 1)
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [orange.withAlphaComponent(0.10).cgColor, orange.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 182, options: [])
    ctx.restoreGState()

    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 262, y: 198))
    arrow.curve(to: CGPoint(x: 392, y: 190), controlPoint1: CGPoint(x: 296, y: 156), controlPoint2: CGPoint(x: 360, y: 152))
    arrow.move(to: CGPoint(x: 376, y: 188))
    arrow.line(to: CGPoint(x: 393, y: 192))
    arrow.line(to: CGPoint(x: 395, y: 174))
    arrow.lineWidth = 3.2
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    orange.setStroke()
    arrow.stroke()

    let caption = NSMutableAttributedString(string: "Drag Burn", attributes: [
        .font: font("BricolageGrotesque12pt-Bold.ttf", 15), .foregroundColor: color(0x1C1A17), .kern: -0.15,
    ])
    caption.append(NSAttributedString(string: " to Applications", attributes: [
        .font: font("BricolageGrotesque12pt-Medium.ttf", 15), .foregroundColor: color(0x7A746C), .kern: -0.15,
    ]))
    let textSize = caption.size()
    caption.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: size.height - 34 - textSize.height))
}

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(in: cg)
    NSGraphicsContext.current = nil
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}
