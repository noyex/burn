import Foundation

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

/// Runs a process without blocking the caller; kills it after `timeout` seconds.
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: Data) {
    let box = ProcessBox()
    box.process.executableURL = URL(fileURLWithPath: path)
    box.process.arguments = args
    let out = Pipe()
    box.process.standardOutput = out
    box.process.standardError = FileHandle.nullDevice
    box.process.standardInput = FileHandle.nullDevice

    return try await withCheckedThrowingContinuation { cont in
        // Drain stdout on its own thread so a chatty child can't fill the pipe and stall.
        let drained = DispatchGroup()
        let buffer = DataBuffer()
        drained.enter()
        DispatchQueue.global().async {
            buffer.set(out.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        box.process.terminationHandler = { proc in
            drained.notify(queue: .global()) {
                cont.resume(returning: (proc.terminationStatus, buffer.get()))
            }
        }
        do {
            try box.process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            box.process.terminationHandler = nil
            cont.resume(throwing: error)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Quick synchronous variant for cheap local checks.
func runProcessSync(_ path: String, _ args: [String]) -> (status: Int32, stdout: Data)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

/// Reads a generic-password keychain item via the `security` CLI. Nil if absent.
func keychainPassword(service: String, account: String? = nil) async -> String? {
    var args = ["find-generic-password", "-s", service]
    if let account { args += ["-a", account] }
    args.append("-w")
    guard let r = try? await runProcess("/usr/bin/security", args, timeout: 10), r.status == 0 else { return nil }
    let s = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

func keychainItemExists(service: String, account: String? = nil) -> Bool {
    var args = ["find-generic-password", "-s", service]
    if let account { args += ["-a", account] }
    return runProcessSync("/usr/bin/security", args)?.status == 0
}

/// Performs a request with a 15 s timeout and returns status + body.
func httpData(_ request: URLRequest) async throws -> (status: Int, data: Data) {
    var req = request
    req.timeoutInterval = 15
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw LimitsError.badResponse }
    return (http.statusCode, data)
}

func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

/// JSON number that may arrive as a number or a numeric string.
func jsonDouble(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}
