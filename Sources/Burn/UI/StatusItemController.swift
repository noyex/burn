import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let host: NSHostingController<PopoverView>
    private let panel = FloatingPanel()
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClicks: Any?
    private var spaceChanges: NSObjectProtocol?
    /// Bumped on every open so a fade-out that finishes late doesn't hide a reopened panel.
    private var generation = 0

    init(model: AppModel) {
        self.model = model
        host = NSHostingController(rootView: PopoverView(model: model))
        super.init()
        host.sizingOptions = .preferredContentSize
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel.contentView = host.view
        panel.onCancel = { [weak self] in self?.close() }
        sizeObservation = host.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.place() }
        }

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        model.onMenuBarChange = { [weak self] in self?.render() }
        model.popoverVisible = false
        render()
    }

    @objc private func toggle() {
        panel.isVisible && panel.alphaValue > 0 ? close() : open()
    }

    private func open() {
        generation += 1
        model.popoverOpened()
        place()
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        // Next turn of the run loop, so the content is laid out hidden and animates in.
        DispatchQueue.main.async { [weak self] in self?.model.popoverVisible = true }

        removeMonitors()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in MainActor.assumeIsolated { self?.close() }
        }
        spaceChanges = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        let current = generation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel.orderOut(nil)
                self.model.popoverVisible = false
            }
        }
    }

    private func removeMonitors() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let spaceChanges { NSWorkspace.shared.notificationCenter.removeObserver(spaceChanges) }
        outsideClicks = nil
        spaceChanges = nil
    }

    /// Hangs the panel under the menu bar icon, top edge fixed, kept on screen.
    private func place() {
        guard let button = item.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        var size = host.preferredContentSize
        if size == .zero { size = host.view.fittingSize }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = min(max(icon.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        panel.setFrame(NSRect(x: x, y: icon.minY - 2 - size.height, width: size.width, height: size.height),
                       display: true)
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

/// Borderless, see-through panel: the blocks float over the desktop with nothing behind them.
private final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
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
