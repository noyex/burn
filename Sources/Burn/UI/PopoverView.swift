import Charts
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    @State private var showingSettings = false
    @State private var selection: Set<URL> = []
    @State private var confirmingClear = false
    @State private var copiedSelection = false

    private static let padding: CGFloat = 14
    private var expanded: Bool { !showingSettings && model.settings.tab == .shelf && model.settings.shelfExpanded }
    private var width: CGFloat { expanded ? 660 : 320 }

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(model: model) { showingSettings = false }
            } else {
                main
            }
        }
        .padding(Self.padding)
        .frame(width: width)
    }

    private var main: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GlassSegmented(options: PopoverTab.allCases, selection: $settings.tab, accessibilityLabel: "View") { $0.title }
                if settings.tab == .shelf { expandButton }
            }
            switch settings.tab {
            case .usage: usage
            case .shelf:
                ShelfView(shelf: model.shelf, width: width - Self.padding * 2,
                          columns: expanded ? 4 : 2, maxHeight: expanded ? 560 : 380,
                          selection: $selection)
            }
            footer.padding(.top, -2)
        }
    }

    private var expandButton: some View {
        let expanded = model.settings.shelfExpanded
        return GlassIconButton(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: expanded ? "Make shelf smaller" : "Make shelf bigger") {
            model.settings.shelfExpanded.toggle()
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.connected.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in to a provider in Terminal:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(ProviderID.allCases) { p in
                        HStack(spacing: 8) {
                            ProviderGlyph(provider: p)
                            CommandChip(command: p.loginCommand)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.connected) { p in
                        ProviderLimitsView(provider: p, state: model.limits[p] ?? .loading,
                                           menuBarWindowID: menuBarWindowID(p))
                    }
                }
            }
            if model.hasUsage {
                Divider().padding(.vertical, 12)
                UsageView(model: model)
            } else if let pct = model.importPercent {
                Divider().padding(.vertical, 12)
                ProgressView(value: Double(pct), total: 100) {
                    Text("Importing usage from Claude Code and Codex logs…").font(.caption)
                }
                .controlSize(.small)
            }
        }
    }

    private func menuBarWindowID(_ p: ProviderID) -> String? {
        guard model.settings.showsInMenuBar(p), let l = model.limits[p]?.limits else { return nil }
        return model.menuBarWindow(for: l)?.id
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch model.settings.tab {
            case .usage: syncStatus
            case .shelf: shelfActions
            }
            GlassIconButton(systemName: "gearshape", label: "Settings", size: 26) { showingSettings = true }
        }
        .font(.caption)
    }

    private var syncStatus: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(model.syncing ? "Syncing…" : Format.synced(model.lastSync, now: ctx.date))
                    .opacity(model.hasUsage ? 1 : 0)
            }
            .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    @ViewBuilder
    private var shelfActions: some View {
        let items = model.shelf.items
        let selected = items.filter { selection.contains($0.id) }
        if selected.isEmpty {
            Text(items.isEmpty ? "" : items.count == 1 ? "1 screenshot" : "\(items.count) screenshots")
                .foregroundStyle(.tertiary)
            Spacer()
            if !items.isEmpty {
                Button(confirmingClear ? "Clear all?" : "Clear") {
                    if confirmingClear {
                        confirmingClear = false
                        withAnimation(.snappy) { model.shelf.clear() }
                    } else {
                        confirmingClear = true
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            confirmingClear = false
                        }
                    }
                }
                .foregroundStyle(confirmingClear ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .glassButton()
                .controlSize(.small)
            }
        } else {
            Text("\(selected.count) selected").foregroundStyle(.secondary)
            Spacer()
            Button("Deselect") { selection = [] }
                .glassButton()
                .controlSize(.small)
            Button {
                model.shelf.copy(selected)
                copiedSelection = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copiedSelection = false
                }
            } label: {
                Text(copiedSelection ? "Copied" : "Copy \(selected.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 56)
            }
            .glassButton(prominent: true)
            .controlSize(.small)
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
            if case .signedOut = state {
                Text("Signed out. Sign in again in Terminal:").font(.caption).foregroundStyle(.secondary)
                CommandChip(command: provider.loginCommand)
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
            GlassSegmented(options: Period.allCases, selection: $model.period, accessibilityLabel: "Period") { $0.title }

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
            // Zero points keep empty buckets on the axis so bars line up with the period labels.
            ProviderID.allCases.map { p in Point(start: b.start, provider: p, cost: b.cost[p] ?? 0) }
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
