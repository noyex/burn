// Renders assets/AppIcon.icns: white "brn" in Bricolage Grotesque on an orange squircle.
import AppKit
import CoreText

let out = CommandLine.arguments[1]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontURL = root.appendingPathComponent("assets/fonts/BricolageGrotesque-Display-ExtraBold.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Burn.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let orange = NSColor(srgbRed: 0.941, green: 0.306, blue: 0.078, alpha: 1) // #F04E14

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    orange.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225).fill()

    // Size the word's ink to a fixed share of the tile width, then center it on its x-height.
    func line(_ size: CGFloat) -> (CTLine, NSFont) {
        let font = NSFont(name: "BricolageGrotesque96pt-ExtraBold", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
        let text = NSAttributedString(string: "brn", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -size * 0.012])
        return (CTLineCreateWithAttributedString(text), font)
    }
    let ctx = NSGraphicsContext.current!.cgContext
    let probe = CTLineGetImageBounds(line(100).0, ctx)
    let (word, font) = line(100 * r.width * 0.76 / probe.width)
    let ink = CTLineGetImageBounds(word, ctx)
    let x = (s - ink.width) / 2 - ink.minX
    let y = (s - font.xHeight) / 2
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(word, ctx)

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
