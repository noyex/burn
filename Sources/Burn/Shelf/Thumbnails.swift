import AppKit
import ImageIO

/// Downscaled previews of shelf images; full-size screenshots are too heavy to draw in a grid.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let maxPixels = 640

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        let maxPixels = maxPixels
        let cg = await Task.detached { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
