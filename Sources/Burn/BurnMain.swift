import AppKit
import SwiftUI

@main
@MainActor
enum BurnMain {
    private static var delegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--dump") {
            Task {
                await runDebugDump()
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--verify-t3") {
            runVerifyT3()
            exit(0)
        }
        if CommandLine.arguments.contains("--import") {
            Task {
                await runDebugImport()
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let preview = CommandLine.arguments.contains("--preview")
        if preview {
            previewWindow = Self.makePreviewWindow(model: model)
        } else {
            statusItem = StatusItemController(model: model)
        }
        // A preview next to the installed app would save every copied image twice.
        model.start(capturingClipboard: !preview)
    }

    /// Development aid: the popover content in a plain off-screen window that stays open,
    /// so it can be captured with `screencapture -l` and driven through Accessibility.
    private static func makePreviewWindow(model: AppModel) -> NSWindow {
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .fullSizeContentView]
        window.title = "Burn"
        window.titlebarAppearsTransparent = true
        window.setFrameTopLeftPoint(NSPoint(x: -3000, y: 1000))
        window.orderFrontRegardless()
        return window
    }
}
