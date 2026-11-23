import AppKit
import SwiftUI

/// The System tab: free disk space, CPU, memory, battery, network and the apps using the
/// most memory, as blocks in the theme's colors.
struct SystemView: View {
    let monitor: SystemMonitor
    let visible: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var hoveringBattery = false

    private var theme: Theme { Theme(scheme) }
    private var snap: SystemSnapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: Bento.gap) {
            disk.reveal(visible, index: 0)
            HStack(alignment: .top, spacing: Bento.gap) {
                cpu
                memory
            }
            .fixedSize(horizontal: false, vertical: true)
            .reveal(visible, index: 1)
            HStack(alignment: .top, spacing: Bento.gap) {
                if let battery = snap.battery { self.battery(battery) }
                network
            }
            .fixedSize(horizontal: false, vertical: true)
            .reveal(visible, index: 2)
            apps.reveal(visible, index: 3)
        }
    }

    // MARK: Disk

    private var disk: some View {
        let color = CardColor.mono
        let ink = theme.ink(color)
        let d = snap.disk
        let level = d.map { MenuBarImage.Level(free: $0.free) } ?? .normal
        return VStack(alignment: .leading, spacing: 0) {
            header("Disk", ink: ink) {
                if let d {
                    if level != .normal { alertPill(level == .full ? "Full" : "Low", level: level, on: color) }
                    Text("\(Format.bytes(d.used)) of \(Format.bytes(d.total)) used").font(.brand(11)).opacity(0.65)
                }
            }
            Spacer(minLength: 10)
            if let d {
                let (number, unit) = Format.bytesParts(d.free)
                BigValue(number: number, unit: "\(unit) free", size: 44, color: ink)
                Meter(fraction: Double(d.used) / Double(max(d.total, 1)), ink: ink).padding(.top, 10)
            } else {
                placeholder(ink: ink, width: 130, height: 40)
                placeholder(ink: ink, height: 6).padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .foregroundStyle(ink)
        .block(color.tokens.fill)
        .environment(\.blockLevel, d.map { Double($0.free) / Double(max($0.total, 1)) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk")
        .accessibilityValue(d.map { "\(Format.bytes($0.free)) free of \(Format.bytes($0.total))" } ?? "Loading")
    }

    // MARK: CPU

    private var cpu: some View {
        let ink = theme.accentInk
        return VStack(alignment: .leading, spacing: 0) {
            header("CPU", ink: ink) { EmptyView() }
            Spacer(minLength: 10)
            if let cpu = snap.cpu {
                BigPercent(value: Int(cpu.rounded()), size: 32, color: ink)
                Sparkline(values: monitor.cpuHistory, ink: ink)
                    .frame(height: 22)
                    .padding(.top, 8)
            } else {
                placeholder(ink: ink, width: 56, height: 28)
                placeholder(ink: ink, height: 22).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ink)
        .block(.accent)
        .environment(\.blockLevel, snap.cpu.map { 1 - $0 / 100 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU")
        .accessibilityValue(snap.cpu.map { "\(Int($0.rounded()))% busy" } ?? "Loading")
    }

    // MARK: Memory

    private var memory: some View {
        let color = CardColor.lavender
        let ink = theme.ink(color)
        let m = snap.memory
        let level = m.map { MenuBarImage.Level($0.pressure) } ?? .normal
        return VStack(alignment: .leading, spacing: 0) {
            header("Memory", ink: ink) {
                if level != .normal { alertPill(level == .full ? "Full" : "Low", level: level, on: color) }
            }
            Spacer(minLength: 10)
            if let m {
                let (used, _) = Format.memoryParts(m.used)
                let (total, unit) = Format.memoryParts(m.total)
                BigValue(number: used, unit: "/ \(total) \(unit)", size: 32, color: ink)
                Meter(fraction: Double(m.used) / Double(max(m.total, 1)), ink: ink).padding(.top, 8)
                Text(pressureText(m.pressure)).font(.brand(11)).opacity(0.75).padding(.top, 6)
            } else {
                placeholder(ink: ink, width: 80, height: 28)
                placeholder(ink: ink, height: 6).padding(.top, 8)
                placeholder(ink: ink, width: 70, height: 9).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ink)
        .block(color.tokens.fill)
        .environment(\.blockLevel, m.map { 1 - Double($0.used) / Double(max($0.total, 1)) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue(m.map { "\(Format.memory($0.used)) of \(Format.memory($0.total)) used, \(pressureText($0.pressure))" } ?? "Loading")
    }

    private func pressureText(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "Running smoothly"
        case .warning: "Getting tight"
        case .critical: "Out of memory"
        }
    }

    // MARK: Battery

    private func battery(_ b: SystemSnapshot.Battery) -> some View {
        let ink = theme.ink(.sky)
        return VStack(alignment: .leading, spacing: 0) {
            header("Battery", ink: ink) {
                if b.charging || b.pluggedIn {
                    Image(systemName: b.charging ? "bolt.fill" : "powerplug.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.75)
                }
            }
            Spacer(minLength: 10)
            BigPercent(value: b.percent, size: 32, color: ink)
            Text(batteryCaption(b)).font(.brand(11)).opacity(0.75).lineLimit(1).padding(.top, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ink)
        .block(CardColor.sky.tokens.fill)
        .environment(\.blockLevel, Double(b.percent) / 100)
        .hoverTip(batteryTip(b), isShown: hoveringBattery && !batteryTip(b).isEmpty)
        .onHover { hoveringBattery = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue("\(b.percent)%, \(batteryCaption(b))")
    }

    private func batteryCaption(_ b: SystemSnapshot.Battery) -> String {
        if b.charging { return b.minutes.map { "\(Format.minutes($0)) to full" } ?? "Charging" }
        if b.pluggedIn { return "Plugged in" }
        return b.minutes.map { "\(Format.minutes($0)) left" } ?? "On battery"
    }

    private func batteryTip(_ b: SystemSnapshot.Battery) -> String {
        [b.health.map { "Health \($0)%" }, b.cycles.map { "\($0) cycles" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Network

    private var network: some View {
        let color = CardColor.coral
        let ink = theme.ink(color)
        return VStack(alignment: .leading, spacing: 0) {
            header("Network", ink: ink) { EmptyView() }
            Spacer(minLength: 10)
            if let n = snap.network {
                rateRow("arrow.down", Format.rate(n.down), size: 20, ink: ink)
                rateRow("arrow.up", Format.rate(n.up), size: 13, ink: ink).opacity(0.75).padding(.top, 4)
            } else {
                placeholder(ink: ink, width: 90, height: 20)
                placeholder(ink: ink, width: 64, height: 11).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 92)
        .foregroundStyle(ink)
        .block(color.tokens.fill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network")
        .accessibilityValue(snap.network.map { "Down \(Format.rate($0.down)), up \(Format.rate($0.up))" } ?? "Loading")
    }

    private func rateRow(_ symbol: String, _ text: String, size: CGFloat, ink: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: size * 0.6, weight: .bold))
            Text(text)
                .font(.brand(size, size > 14 ? .display : .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: text)
        }
        .foregroundStyle(ink)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: Apps

    private var apps: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Using most memory", ink: theme.text) { EmptyView() }
            VStack(spacing: 0) {
                if snap.apps.isEmpty {
                    ForEach(0..<SystemMonitor.appCount, id: \.self) { _ in
                        HStack(spacing: 8) {
                            placeholder(ink: theme.text, width: 16, height: 16)
                            placeholder(ink: theme.text, width: 90, height: 10)
                            Spacer()
                            placeholder(ink: theme.text, width: 64, height: 10)
                        }
                        .frame(height: 26)
                    }
                } else {
                    ForEach(snap.apps) { app in appRow(app) }
                }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(theme.text)
        .block(.neutral)
    }

    private func appRow(_ app: SystemSnapshot.App) -> some View {
        HStack(spacing: 8) {
            AppIcon(bundlePath: app.bundlePath, ink: theme.secondary)
            Text(app.name).font(.brand(12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            Text(Format.memory(app.memory)).font(.brand(12, .bold)).monospacedDigit()
            Text("\(Int(app.cpu.rounded()))%")
                .font(.brand(11))
                .monospacedDigit()
                .foregroundStyle(theme.secondary)
                .frame(minWidth: 30, alignment: .trailing)
                .hoverTip("CPU")
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("\(Format.memory(app.memory)) memory, \(Int(app.cpu.rounded()))% CPU")
    }

    // MARK: Pieces

    private func header(_ title: String, ink: Color, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.brand(12, .bold))
            Spacer(minLength: 4)
            trailing()
        }
        .foregroundStyle(ink)
        .lineLimit(1)
    }

    private func alertPill(_ title: String, level: MenuBarImage.Level, on color: CardColor) -> some View {
        Text(title).font(.brand(10, .bold))
            .foregroundStyle(theme.alert(level, on: color))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.ink(color), in: Bento.pill)
    }

    private func placeholder(ink: Color, width: CGFloat? = nil, height: CGFloat) -> some View {
        Pulse { Bento.pill.fill(ink.opacity(0.18)).frame(width: width, height: height) }
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A big number with a smaller unit after it: "182 GB free".
private struct BigValue: View {
    let number: String
    let unit: String
    let size: CGFloat
    let color: Color

    var body: some View {
        (Text(number).font(.brand(size, .display)).kerning(-size * 0.03)
            + Text(" " + unit).font(.brand(size * 0.42, .display)))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.3), value: number)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Thin bar of how much is used.
private struct Meter: View {
    let fraction: Double
    let ink: Color

    var body: some View {
        GeometryReader { geo in
            Bento.pill.fill(ink.opacity(0.2))
                .overlay(alignment: .leading) {
                    Bento.pill.fill(ink).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: 6)
        .animation(.snappy(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// Recent CPU readings as a line, 0% at the bottom and 100% at the top.
private struct Sparkline: View {
    let values: [Double]
    let ink: Color

    var body: some View {
        Canvas { ctx, size in
            let count = SystemMonitor.historyLength
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.75))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.75))
            ctx.stroke(base, with: .color(ink.opacity(0.2)), lineWidth: 1.5)
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(count - 1)
            // Newest on the right edge; the line grows in from there.
            let start = CGFloat(count - values.count) * step
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: start + CGFloat(i) * step,
                                y: 1 + (size.height - 2) * (1 - CGFloat(min(max(v, 0), 100)) / 100))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(ink.opacity(0.12)))
            ctx.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// The app's own icon, or a terminal glyph for a command-line process like `node`.
private struct AppIcon: View {
    let bundlePath: String?
    let ink: Color

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let bundlePath {
                Image(nsImage: Self.icon(bundlePath)).resizable().interpolation(.high)
            } else {
                Image(systemName: "terminal").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private static func icon(_ path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

extension MenuBarImage.Level {
    init(free: Int64) {
        self = free < SystemMonitor.diskFull ? .full : free < SystemMonitor.diskLow ? .warn : .normal
    }

    init(_ pressure: MemoryPressure) {
        switch pressure {
        case .normal: self = .normal
        case .warning: self = .warn
        case .critical: self = .full
        }
    }
}
