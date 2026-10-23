import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        statusItem = StatusItemController(model: model)
        model.start()
    }
}
