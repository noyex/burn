import Testing
@testable import Burn

struct SystemStatsTests {
    @Test func helpersBelongToTheirApp() {
        let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(SystemSampler.appBundle(forExecutable: chrome) == "/Applications/Google Chrome.app")
        let simulator = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
        #expect(SystemSampler.appBundle(forExecutable: simulator) == "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
        #expect(SystemSampler.appBundle(forExecutable: "/opt/homebrew/bin/node") == nil)
    }

    @Test func cpuBusyShare() {
        // user, system, idle, nice
        #expect(SystemSampler.busyPercent(from: [0, 0, 0, 0], to: [20, 5, 75, 0]) == 25)
        #expect(SystemSampler.busyPercent(from: [5, 5, 5, 5], to: [5, 5, 5, 5]) == nil)
    }

    @Test func bytes() {
        #expect(Format.bytes(182_400_000_000) == "182 GB")
        #expect(Format.bytes(8_400_000_000) == "8.4 GB")
        #expect(Format.bytes(1_200_000_000_000) == "1.2 TB")
        #expect(Format.rate(4_200_000) == "4.2 MB/s")
        #expect(Format.rate(300) == "0 KB/s")
        #expect(Format.minutes(250) == "4h 10m")
        #expect(Format.memory(34_359_738_368) == "32 GB")
        #expect(Format.bytes(9_960_000_000) == "10 GB")
        #expect(Format.bytes(999_700_000_000) == "1 TB")
        #expect(Format.rate(999_999) == "1 MB/s")
    }

    @MainActor @Test func alertPicksTheUrgentOne() {
        let roomy = SystemSnapshot.Disk(total: 1_000_000_000_000, free: 200_000_000_000)
        let low = SystemSnapshot.Disk(total: 1_000_000_000_000, free: 6_000_000_000)
        let full = SystemSnapshot.Disk(total: 1_000_000_000_000, free: 1_000_000_000)
        #expect(SystemAlert(disk: roomy, pressure: .normal) == nil)
        #expect(SystemAlert(disk: low, pressure: .normal)?.level == .warn)
        #expect(SystemAlert(disk: low, pressure: .critical)?.kind == .memory)
        #expect(SystemAlert(disk: full, pressure: .critical)?.kind == .disk(free: 1_000_000_000))
        #expect(SystemAlert(disk: roomy, pressure: .warning)?.kind == .memory)
        let edge = SystemSnapshot.Disk(total: 1_000_000_000_000, free: 10_500_000_000)
        #expect(SystemAlert(disk: edge, pressure: .normal) == nil)
        #expect(SystemAlert(disk: edge, pressure: .normal, margin: 1_000_000_000)?.level == .warn)
    }

    @Test func readsThisMac() async {
        let sampler = SystemSampler()
        _ = await sampler.sample(apps: 4)
        // CPU ticks advance every ~10 ms; give the second reading something to compare.
        try? await Task.sleep(for: .milliseconds(200))
        let s = await sampler.sample(apps: 4)
        #expect((s.disk?.total ?? 0) > 0)
        #expect((s.memory?.total ?? 0) > 0)
        #expect(s.cpu != nil)
        #expect(!s.apps.isEmpty)
    }
}
