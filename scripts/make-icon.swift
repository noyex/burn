// Renders assets/AppIcon.icns: white "BRN" in Bricolage Grotesque on an orange squircle.
import AppKit
import CoreText

let out = CommandLine.arguments[1]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontURL = root.appendingPathComponent("assets/fonts/BricolageGrotesque-Display-ExtraBold.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Burn.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let orange = NSColor(srgbRed: 1.0, green: 0.353, blue: 0.122, alpha: 1) // #FF5A1F

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    orange.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225).fill()

    // Size the word to a fixed share of the tile width, then center it on its cap height.
    func attributed(_ size: CGFloat) -> NSAttributedString {
        let font = NSFont(name: "BricolageGrotesque96pt-ExtraBold", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
        return NSAttributedString(string: "BRN", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -size * 0.012])
    }
    let probe = attributed(100)
    let text = attributed(100 * r.width * 0.76 / probe.size().width)
    let font = text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    let line = CTLineCreateWithAttributedString(text)
    let ctx = NSGraphicsContext.current!.cgContext
    let ink = CTLineGetImageBounds(line, ctx)
    let x = (s - ink.width) / 2 - ink.minX
    let y = (s - font.capHeight) / 2
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
print("Wrote \(out)")
