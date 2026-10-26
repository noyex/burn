import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        model.onMenuBarChange = { [weak self] in self?.render() }
        render()
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.popoverOpened()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func render() {
        let entries = model.menuBarEntries
        let image = MenuBarImage.make(entries: entries)
        item.button?.image = image
        item.button?.setAccessibilityLabel(
            entries.isEmpty ? "Burn"
                : entries.map { "\($0.provider.name) \(Format.remaining($0.percent)) left" }.joined(separator: ", "))
    }
}

/// Draws provider logos + percentages as one image. The drawing handler runs at draw time,
/// so `labelColor` resolves against the menu bar's current appearance.
enum MenuBarImage {
    nonisolated(unsafe) private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private static let iconSize: CGFloat = 13
    private static let iconGap: CGFloat = 4
    private static let entryGap: CGFloat = 10
    private static let height: CGFloat = 18

    @MainActor
    static func make(entries: [AppModel.MenuBarEntry]) -> NSImage {
        guard !entries.isEmpty else {
            let img = NSImage(systemSymbolName: "flame", accessibilityDescription: "Burn") ?? NSImage()
            img.isTemplate = true
            return img
        }
        struct Part { let icon: CGImage?; let text: String; let level: Level }
        let parts = entries.map { e -> Part in
            var text = Format.remaining(e.percent)
            if e.percent >= 100, e.resetsAt != nil { text += " · " + Format.shortReset(e.resetsAt) }
            let icon = ProviderIcon.image(e.provider)
            var rect = CGRect(x: 0, y: 0, width: iconSize * 2, height: iconSize * 2)
            return Part(icon: icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                        text: text, level: Level(e.percent))
        }
        let widths = parts.map { iconSize + iconGap + ceil(($0.text as NSString).size(withAttributes: [.font: font]).width) }
        let total = widths.reduce(0, +) + entryGap * CGFloat(parts.count - 1)

        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for (part, width) in zip(parts, widths) {
                let color = part.level.color
                if let icon = part.icon {
                    let r = CGRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                    ctx.saveGState()
                    ctx.clip(to: r, mask: icon)
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(r)
                    ctx.restoreGState()
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = (part.text as NSString).size(withAttributes: attrs)
                (part.text as NSString).draw(at: NSPoint(x: x + iconSize + iconGap, y: (height - size.height) / 2), withAttributes: attrs)
                x += width + entryGap
            }
            return true
        }
        image.cacheMode = .never
        return image
    }

    enum Level {
        case normal, warn, full
        init(_ percent: Double) {
            self = percent >= 100 ? .full : percent >= AppModel.warnPercent ? .warn : .normal
        }
        var color: NSColor {
            switch self {
            case .normal: .labelColor
            case .warn: .systemOrange
            case .full: .systemRed
            }
        }
    }
}
