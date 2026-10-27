import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var host: NSHostingController<PopoverView>!
    private let panel = FloatingPanel()
    /// What the SwiftUI content last asked for; the panel follows it.
    private var contentSize = NSSize.zero
    private var outsideClicks: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isOpen = false
    private var pendingShrink: DispatchWorkItem?
    private var resizeObserver: NSObjectProtocol?
    /// Fixed size of the hosting view, larger than the content can ever get.
    private static let canvas = NSSize(width: 1000, height: 1600)
    /// Bumped on every open so a fade-out that finishes late doesn't hide a reopened panel.
    private var generation = 0

    init(model: AppModel) {
        self.model = model
        super.init()
        host = NSHostingController(rootView: PopoverView(model: model) { [weak self] size in
            self?.resize(to: size)
        })
        // Sized by hand from what the content reports, so nothing else fights over the frame.
        host.sizingOptions = []
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        // The hosting view never changes size: it hangs, centered, from the top of a plain
        // container, and the panel only decides how much of it shows. If SwiftUI saw its size
        // change, it would re-center the old content for a frame before animating it back up.
        let container = CanvasContainer()
        container.wantsLayer = true
        host.view.frame.size = Self.canvas
        container.addSubview(host.view)
        panel.contentView = container
        panel.onCancel = { [weak self] in self?.close() }
        // Whatever resizes the panel, it must not end up past the edge of the screen.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        model.onMenuBarChange = { [weak self] in self?.render() }
        model.popoverVisible = false
        render()
    }

    @objc private func toggle() {
        isOpen ? close() : open()
    }

    private func open() {
        isOpen = true
        generation += 1
        model.popoverOpened()
        place()
        // Through the animator, so it replaces a fade-out that is still running.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.makeKeyAndOrderFront(nil)
        // Next turn of the run loop, so the content is laid out hidden and animates in.
        DispatchQueue.main.async { [weak self] in self?.model.popoverVisible = true }

        removeMonitors()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in MainActor.assumeIsolated { self?.close() }
        }
        // Like a transient popover: switching apps or Spaces from the keyboard closes it too.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification]
            .map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                }
            }
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
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
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        outsideClicks = nil
        workspaceObservers = []
    }

    /// Grows the panel at once. A change in width slides along with SwiftUI's animation, so the
    /// content doesn't snap sideways when it re-centers under the icon; a shorter one shrinks only
    /// after the content has animated up, so it isn't clipped mid-animation.
    private func resize(to size: CGSize) {
        guard size != contentSize, size.width > 0, size.height > 0 else { return }
        contentSize = size
        pendingShrink?.cancel()
        if size.width != panel.frame.width {
            return place(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        guard size.height < panel.frame.height else { return place() }
        let shrink = DispatchWorkItem { [weak self] in self?.place() }
        pendingShrink = shrink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: shrink)
    }

    /// Hangs the panel under the menu bar icon, top edge fixed, kept on screen.
    private func place(animated: Bool = false) {
        guard let button = item.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        // Before the first open nothing has been laid out yet; doing it reports the size.
        if contentSize == .zero { host.view.layoutSubtreeIfNeeded() }
        let size = contentSize
        guard size != .zero else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = max(min(icon.midX - size.width / 2, visible.maxX - size.width), visible.minX)
        let frame = NSRect(x: x, y: icon.minY - 2 - size.height, width: size.width, height: size.height)
        guard animated, panel.isVisible else { return panel.setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Slides the panel back inside the screen horizontally, keeping its size and top edge.
    private func keepOnScreen() {
        guard let screen = item.button?.window?.screen ?? panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        let x = max(min(frame.minX, visible.maxX - frame.width), visible.minX)
        guard x != frame.minX else { return }
        frame.origin.x = x
        panel.setFrame(frame, display: true)
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

/// Keeps its only subview, the fixed-size canvas, centered and hanging from the top edge,
/// on every resize including each step of an animated one.
private final class CanvasContainer: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews {
            view.setFrameOrigin(NSPoint(x: ((bounds.width - view.frame.width) / 2).rounded(),
                                        y: bounds.height - view.frame.height))
        }
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
            if Level(e.percent) == .full, e.resetsAt != nil { text += " · " + Format.shortReset(e.resetsAt) }
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
            // From the rounded share left, so a block reading "0%" is always .full.
            let left = min(max(100 - percent, 0), 100).rounded()
            self = left <= 0 ? .full : left <= 100 - AppModel.warnPercent ? .warn : .normal
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
