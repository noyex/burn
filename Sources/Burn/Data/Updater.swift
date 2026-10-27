import AppKit
import Foundation
import Observation

/// Checks GitHub for a newer release and replaces the running app with it on request.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let zip: URL
        let page: URL
    }

    enum State: Equatable {
        case idle
        case installing
    }

    /// Set when the latest release is newer than this build.
    private(set) var available: Release?
    private(set) var state: State = .idle

    nonisolated static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    nonisolated private static let latestURL = URL(string: "https://api.github.com/repos/noyex/burn/releases/latest")!

    func check() async {
        // Builds without a release tag report 0.0.0; there's nothing sensible to compare them with.
        guard Self.current != "0.0.0", state == .idle else { return }
        var req = URLRequest(url: Self.latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (status, data) = try? await httpData(req), status == 200,
              let release = Self.parse(data), Self.isNewer(release.version, than: Self.current) else { return }
        available = release
    }

    /// Downloads the release, swaps it in once this process exits and relaunches.
    /// Falls back to the release page when the app can't replace itself.
    func install() {
        guard let release = available, state == .idle else { return }
        let dest = Bundle.main.bundleURL
        let fm = FileManager.default
        // A translocated or read-only copy (e.g. run straight from the DMG) can't be swapped in place.
        guard fm.isWritableFile(atPath: dest.path),
              fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .installing
        Task {
            do {
                let tmp = try await Self.download(release)
                try Self.relaunch(replacing: dest, with: tmp.appendingPathComponent("Burn.app"), cleaning: tmp)
                NSApp.terminate(nil)
            } catch {
                NSLog("Burn: update failed: \(error)")
                state = .idle
                NSWorkspace.shared.open(release.page)
            }
        }
    }

    // MARK: Steps

    enum UpdateError: Error {
        case download
        case badArchive
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { $0["name"] as? String == "Burn.zip" })?["browser_download_url"] as? String,
              let zipURL = URL(string: zip) else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zip: zipURL, page: page)
    }

    /// Numeric, component-wise comparison: 1.10.0 is newer than 1.9.2.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads and unpacks the release into a fresh temporary directory, then checks it's really Burn
    /// at the advertised version.
    nonisolated private static func download(_ release: Release) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("burn-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            var req = URLRequest(url: release.zip)
            req.timeoutInterval = 60
            let (file, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let zip = tmp.appendingPathComponent("Burn.zip")
            try FileManager.default.moveItem(at: file, to: zip)
            let unzip = try await runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path], timeout: 60)
            guard unzip.status == 0 else { throw UpdateError.badArchive }

            let app = tmp.appendingPathComponent("Burn.app")
            guard let info = Bundle(url: app)?.infoDictionary,
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.badArchive }
            return tmp
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Starts a detached script that waits for this process to exit, swaps the bundle (restoring the old one
    /// if the copy fails) and opens the result.
    nonisolated private static func relaunch(replacing dest: URL, with app: URL, cleaning tmp: URL) throws {
        let script = """
        pid="$1"; new="$2"; dest="$3"; tmp="$4"
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        rm -rf "$dest.old"
        if mv "$dest" "$dest.old"; then
          if ditto "$new" "$dest"; then rm -rf "$dest.old"; else rm -rf "$dest"; mv "$dest.old" "$dest"; fi
        fi
        xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        rm -rf "$tmp"
        open "$dest"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "burn-update",
                       String(ProcessInfo.processInfo.processIdentifier), app.path, dest.path, tmp.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
