import Darwin
import Foundation
import IOKit
import IOKit.ps

/// One reading of the Mac's disk, CPU, memory, battery, network and busiest apps.
struct SystemSnapshot: Equatable, Sendable {
    struct Disk: Equatable, Sendable {
        let total: Int64
        /// What Finder calls available: free space plus what macOS can purge on demand.
        let free: Int64
        var used: Int64 { max(total - free, 0) }
    }

    struct Memory: Equatable, Sendable {
        /// App memory + wired + compressed, like "Memory Used" in Activity Monitor.
        let used: UInt64
        let total: UInt64
        let pressure: MemoryPressure
    }

    struct Battery: Equatable, Sendable {
        let percent: Int
        let charging: Bool
        let pluggedIn: Bool
        /// Minutes to empty on battery, or to full while charging; nil while macOS estimates.
        let minutes: Int?
        /// Full charge capacity against the design capacity, 0...100.
        let health: Int?
        let cycles: Int?
    }

    /// Bytes per second over Wi-Fi and Ethernet.
    struct Network: Equatable, Sendable {
        let down: Double
        let up: Double
    }

    struct App: Equatable, Sendable, Identifiable {
        /// The app bundle's path, or the process name for a bare binary like `node`.
        let id: String
        let name: String
        let bundlePath: String?
        let memory: UInt64
        /// Share of the whole machine, 0...100.
        let cpu: Double
    }

    var disk: Disk?
    var memory: Memory?
    /// Share of the whole machine busy, 0...100. Nil until two readings exist.
    var cpu: Double?
    var battery: Battery?
    var network: Network?
    var apps: [App] = []
}

enum MemoryPressure: Int, Sendable {
    case normal, warning, critical
}

/// Reads the counters. CPU, network and per-app CPU are rates, so each comes from the
/// difference to the previous reading.
actor SystemSampler {
    private var lastTicks: [UInt64]?
    private var lastNet: (down: UInt64, up: UInt64, at: UInt64)?
    private var lastAppTime: [pid_t: UInt64] = [:]
    private var lastAppAt: UInt64?
    private var batteryInfo: (health: Int?, cycles: Int?, at: Date)?

    private static let nanosPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Forgets the rates, so a reading after a long pause isn't averaged over it.
    func reset() {
        lastTicks = nil
        lastNet = nil
        lastAppTime = [:]
        lastAppAt = nil
    }

    func sample(apps appCount: Int) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.disk = Self.disk()
        s.memory = Self.memory()
        s.cpu = cpu()
        s.battery = battery()
        s.network = network()
        if appCount > 0 { s.apps = apps(top: appCount) }
        return s
    }

    /// The two values the menu bar warns about, cheap enough to read every minute.
    func alertReading() -> (disk: SystemSnapshot.Disk?, pressure: MemoryPressure) {
        (Self.disk(), Self.pressure())
    }

    // MARK: Disk

    static func disk() -> SystemSnapshot.Disk? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return .init(total: Int64(total), free: free)
    }

    // MARK: Memory

    static func memory() -> SystemSnapshot.Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        return .init(used: min(used, total), total: total, pressure: pressure())
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        // 1 normal, 2 warn, 4 critical.
        return level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }

    // MARK: CPU

    private func cpu() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let ticks = [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return nil }
        return Self.busyPercent(from: last, to: ticks)
    }

    /// Ticks are user, system, idle, nice.
    static func busyPercent(from a: [UInt64], to b: [UInt64]) -> Double? {
        let d = zip(a, b).map { $1 >= $0 ? $1 - $0 : 0 }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(d[0] + d[1] + d[3]) / Double(total) * 100
    }

    // MARK: Battery

    private func battery() -> SystemSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d["Type"] as? String == "InternalBattery",
                  let current = d["Current Capacity"] as? Int, let max = d["Max Capacity"] as? Int, max > 0
            else { continue }
            let charging = d["Is Charging"] as? Bool ?? false
            let plugged = d["Power Source State"] as? String == "AC Power"
            let minutes = d[charging ? "Time to Full Charge" : "Time to Empty"] as? Int
            if batteryInfo.map({ Date.now.timeIntervalSince($0.at) > 300 }) ?? true {
                let (health, cycles) = Self.batteryHealth()
                batteryInfo = (health, cycles, .now)
            }
            return .init(percent: current * 100 / max, charging: charging, pluggedIn: plugged,
                         minutes: minutes.flatMap { $0 > 0 ? $0 : nil },
                         health: batteryInfo?.health, cycles: batteryInfo?.cycles)
        }
        return nil
    }

    private static func batteryHealth() -> (Int?, Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        let full = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        let design = int("DesignCapacity")
        let health = full.flatMap { f in design.flatMap { $0 > 0 ? min(f * 100 / $0, 100) : nil } }
        return (health, int("CycleCount"))
    }

    // MARK: Network

    private func network() -> SystemSnapshot.Network? {
        guard let bytes = Self.networkBytes() else { return nil }
        let now = mach_absolute_time()
        defer { lastNet = (bytes.down, bytes.up, now) }
        guard let last = lastNet, now > last.at else { return nil }
        let seconds = Double(now - last.at) * Self.nanosPerTick / 1e9
        guard seconds > 0 else { return nil }
        // A counter that went down was reset (interface came back); count nothing for it.
        let down = bytes.down >= last.down ? Double(bytes.down - last.down) : 0
        let up = bytes.up >= last.up ? Double(bytes.up - last.up) : 0
        return .init(down: down / seconds, up: up / seconds)
    }

    /// Total bytes in and out over Ethernet-type interfaces (Wi-Fi included), from the 64-bit
    /// counters; the 32-bit ones in `getifaddrs` wrap at 4 GB.
    private static func networkBytes() -> (down: UInt64, up: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        var down: UInt64 = 0, up: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let loopback = h2.ifm_flags & IFF_LOOPBACK != 0
                    if !loopback, Int32(h2.ifm_data.ifi_type) == IFT_ETHER {
                        down &+= h2.ifm_data.ifi_ibytes
                        up &+= h2.ifm_data.ifi_obytes
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return (down, up)
    }

    // MARK: Apps

    /// The user's own processes, summed per app, the biggest by memory first.
    private func apps(top: Int) -> [SystemSnapshot.App] {
        let now = mach_absolute_time()
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let wall = lastAppAt.map { Double(now - $0) * Self.nanosPerTick } ?? 0
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

        struct Group { var name: String; var bundle: String?; var memory: UInt64 = 0; var cpuNanos: Double = 0 }
        var groups: [String: Group] = [:]
        var times: [pid_t: UInt64] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4096)
        var nameBuf = [CChar](repeating: 0, count: 256)

        for pid in pids.prefix(max(found, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            // Fails for other users' processes, which leaves just the user's own.
            guard ok == 0 else { continue }
            let time = info.ri_user_time + info.ri_system_time
            times[pid] = time

            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let path = String(cString: pathBuf)
            let key: String, name: String, bundle: String?
            if let app = Self.appBundle(forExecutable: path) {
                key = app
                bundle = app
                name = (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            } else {
                let short = proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0
                    ? String(cString: nameBuf) : (path as NSString).lastPathComponent
                key = short
                bundle = nil
                name = short
            }
            var g = groups[key] ?? Group(name: name, bundle: bundle)
            g.memory += info.ri_phys_footprint
            if wall > 0, let before = lastAppTime[pid], time >= before {
                g.cpuNanos += Double(time - before) * Self.nanosPerTick
            }
            groups[key] = g
        }
        lastAppTime = times
        lastAppAt = now

        return groups
            .map { key, g in
                SystemSnapshot.App(id: key, name: g.name, bundlePath: g.bundle, memory: g.memory,
                                   cpu: wall > 0 ? min(g.cpuNanos / (wall * cores) * 100, 100) : 0)
            }
            .sorted { $0.memory > $1.memory }
            .prefix(top)
            .map { $0 }
    }

    /// The app a process belongs to: the innermost `.app` in its path, unless that one sits in
    /// the outer app's Frameworks, Helpers or XPC services (a browser's renderer helpers belong
    /// to the browser, while Simulator inside Xcode is an app of its own).
    static func appBundle(forExecutable path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var chosen: Int?
        for (i, part) in parts.enumerated() where part.hasSuffix(".app") {
            if let outer = chosen {
                let between = parts[(outer + 1)..<i]
                if between.contains(where: { ["Frameworks", "Helpers", "XPCServices", "PlugIns", "Library"].contains($0) }) {
                    continue
                }
            }
            chosen = i
        }
        return chosen.map { parts[...$0].joined(separator: "/") }
    }
}
