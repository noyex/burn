import AppKit
import SwiftUI

/// AppKit mouse handling for a shelf tile: clicks, hover, a context menu and
/// dragging one or several files out of the popover (SwiftUI can't drag multiple items here).
struct TileInteraction: NSViewRepresentable {
    struct Handlers {
        var click: (_ inCheckbox: Bool, _ modifiers: NSEvent.ModifierFlags) -> Void
        var doubleClick: () -> Void
        var hover: (Bool) -> Void
        /// Files to drag, the pressed tile's first.
        var dragURLs: () -> [URL]
        var menu: () -> NSMenu
    }

    let handlers: Handlers
    /// Top-trailing square that toggles selection instead of copying.
    let checkboxSize: CGFloat

    func makeNSView(context: Context) -> TileInteractionView { TileInteractionView() }

    func updateNSView(_ view: TileInteractionView, context: Context) {
        view.handlers = handlers
        view.checkboxSize = checkboxSize
    }
}

final class TileInteractionView: NSView, NSDraggingSource {
    var handlers: TileInteraction.Handlers?
    var checkboxSize: CGFloat = 0
    private var mouseDownEvent: NSEvent?
    private var dragged = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { handlers?.hover(true) }
    override func mouseExited(with event: NSEvent) { handlers?.hover(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let down = mouseDownEvent, let handlers else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragged = true

        let urls = handlers.dragURLs()
        let origin = convert(down.locationInWindow, from: nil)
        let items = urls.enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = MainActor.assumeIsolated { Thumbnails.cached(url) } ?? NSWorkspace.shared.icon(forFile: url.path)
            let size = Self.dragSize(image.size)
            // Fan the stack out a little so it reads as several files.
            let offset = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: origin.x - size.width / 2 + offset, y: origin.y - size.height / 2 + offset,
                                         width: size.width, height: size.height), contents: image)
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !dragged, let handlers else { return }
        if event.clickCount == 2 {
            handlers.doubleClick()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let inCheckbox = p.x >= bounds.maxX - checkboxSize && p.y <= checkboxSize
        handlers.click(inCheckbox, event.modifierFlags)
    }

    override func menu(for event: NSEvent) -> NSMenu? { handlers?.menu() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    private static func dragSize(_ size: NSSize) -> NSSize {
        let scale = min(160 / max(size.width, 1), 160 / max(size.height, 1), 1)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
