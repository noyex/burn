import Foundation

/// Runs the t3usage.py importer. Returns true on success.
func runUsageSync() async -> Bool {
    let script = NSHomeDirectory() + "/.t3-usage/t3usage.py"
    guard FileManager.default.fileExists(atPath: script) else { return false }
    let framework = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
    let python = FileManager.default.isExecutableFile(atPath: framework) ? framework : "/usr/bin/python3"
    guard let r = try? await runProcess(python, ["-I", script, "sync"], timeout: 120) else { return false }
    return r.status == 0
}
