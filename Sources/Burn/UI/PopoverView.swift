import Charts
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    @State private var showingSettings = false

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(model: model) { showingSettings = false }
            } else {
                main
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.connected.isEmpty {
                Text("No providers signed in. Sign in to Claude Code, Codex or Cursor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.connected) { p in
                        ProviderLimitsView(provider: p, state: model.limits[p] ?? .loading,
                                           menuBarWindowID: menuBarWindowID(p))
                    }
                }
            }
            Divider().padding(.vertical, 12)
            UsageView(model: model)
            footer.padding(.top, 10)
        }
    }

    private func menuBarWindowID(_ p: ProviderID) -> String? {
        guard model.settings.showsInMenuBar(p), let l = model.limits[p]?.limits else { return nil }
        return model.menuBarWindow(for: l)?.id
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(model.syncing ? "Syncing…" : Format.synced(model.lastSync, now: ctx.date))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }
}

// MARK: - Limits

private struct ProviderLimitsView: View {
    let provider: ProviderID
    let state: LimitState
    let menuBarWindowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ProviderGlyph(provider: provider)
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                if let plan = state.limits?.plan {
                    Text(plan).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if case .loading = state { ProgressView().controlSize(.mini) }
            }
            if let limits = state.limits {
                ForEach(limits.windows) { w in
                    LimitRow(window: w, tint: provider.tint, emphasized: w.id == menuBarWindowID)
                }
            }
            if case .failed(let message, _) = state {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct LimitRow: View {
    let window: LimitWindow
    let tint: Color
    let emphasized: Bool

    private var level: MenuBarImage.Level { .init(window.percent) }
    private var barColor: Color {
        switch level {
        case .normal: tint
        case .warn: .orange
        case .full: .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * min(max(window.percent, 0), 100) / 100)
                }
            }
            .frame(height: 6)
            Text(Format.percent(window.percent))
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(barColor))
                .frame(width: 40, alignment: .trailing)
            Text(Format.reset(window.resetsAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 12).monospacedDigit())
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) limit")
        .accessibilityValue("\(Format.percent(window.percent)) used, resets \(Format.reset(window.resetsAt))")
    }
}

// MARK: - Usage

private struct UsageView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Picker("Period", selection: $model.period) {
                ForEach(Period.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let usage = model.usage {
                summary(usage).padding(.top, 12)
            } else if let error = model.usageError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
    }

    @ViewBuilder
    private func summary(_ usage: UsageSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Format.money(usage.cost))
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Spacer()
            Text("\(Format.tokens(usage.tokens)) tokens")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        let split = ProviderID.allCases.compactMap { p in usage.byProvider[p].flatMap { $0 > 0 ? (p, $0) : nil } }
        if split.count > 1 {
            HStack(spacing: 12) {
                ForEach(split, id: \.0) { p, cost in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(p.tint).frame(width: 7, height: 7)
                        Text("\(p.name) \(Format.money(cost))")
                    }
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        UsageChart(usage: usage).padding(.top, 12)
    }
}

private struct UsageChart: View {
    let usage: UsageSummary

    private struct Point: Identifiable {
        let start: Date
        let provider: ProviderID
        let cost: Double
        var id: String { "\(start.timeIntervalSince1970)-\(provider.rawValue)" }
    }

    private var points: [Point] {
        usage.buckets.flatMap { b in
            ProviderID.allCases.compactMap { p in b.cost[p].map { Point(start: b.start, provider: p, cost: $0) } }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart(points) { pt in
                BarMark(x: .value("Time", pt.start, unit: calendarUnit),
                        y: .value("Cost", pt.cost))
                    .foregroundStyle(by: .value("Provider", pt.provider.name))
            }
            .chartForegroundStyleScale(domain: ProviderID.allCases.map(\.name),
                                       range: ProviderID.allCases.map(\.tint))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 44)
            HStack {
                Text(label(usage.buckets.first?.start))
                Spacer()
                Text(usage.period == .today ? "now" : label(usage.buckets.last?.start))
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cost per \(unitName)")
        .accessibilityValue(peakDescription)
    }

    private var calendarUnit: Calendar.Component {
        switch usage.unit {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        }
    }

    private var unitName: String {
        switch usage.unit {
        case .hour: "hour"
        case .day: "day"
        case .week: "week"
        }
    }

    private var peakDescription: String {
        guard let peak = usage.buckets.max(by: { $0.total < $1.total }), peak.total > 0 else { return "No usage" }
        return "Peak \(Format.money(peak.total)) on \(label(peak.start))"
    }

    private func label(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        switch usage.unit {
        case .hour: f.dateFormat = "HH:mm"
        case .day: f.dateFormat = "d MMM"
        case .week: f.dateFormat = "MMM yyyy"
        }
        return f.string(from: date)
    }
}
