import SwiftUI

/// The main tab: a small tile for each provider the user picked, with what's left of its limits,
/// and the system readings they picked. Settings decide what's here; the other tabs show everything.
struct DashboardView: View {
    let model: AppModel
    let visible: Bool
    /// Opens Settings, where the dashboard is put together.
    let onEdit: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var theme: Theme { Theme(scheme) }

    var body: some View {
        let shown = model.dashboardProviders
        let tiles = shown.filter(model.hasCard)
        let issues = shown.filter { !tiles.contains($0) }
        let stats = model.settings.dashboardStats
        let rows = Self.rows(tiles)
        VStack(alignment: .leading, spacing: Bento.gap) {
            if model.connected.isEmpty {
                SignInBlock().reveal(visible, index: 0)
            } else if !tiles.isEmpty {
                CardGrid(rows: rows, spacing: Bento.gap) {
                    ForEach(tiles) { p in
                        tile(p)
                            .reveal(visible, index: rows.firstIndex { $0.contains(p) } ?? 0)
                            .layoutValue(key: CardID.self, value: p)
                    }
                }
            }
            ForEach(issues) { p in
                ProviderIssueRow(provider: p, state: model.limits[p] ?? .loading)
                    .reveal(visible, index: rows.count)
            }
            if !stats.isEmpty {
                DashboardSystem(snapshot: model.system.snapshot, stats: stats)
                    .reveal(visible, index: rows.count + 1)
            }
            if !model.connected.isEmpty, shown.isEmpty, stats.isEmpty {
                empty.reveal(visible, index: 0)
            }
        }
    }

    /// Two tiles a row; an odd one out takes the full width.
    nonisolated static func rows(_ tiles: [ProviderID]) -> [[ProviderID]] {
        stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
    }

    private func tile(_ p: ProviderID) -> some View {
        DashboardTile(provider: p, state: model.limits[p] ?? .loading,
                      primary: model.limits[p]?.limits.flatMap { model.cardWindow(for: $0) },
                      color: model.settings.cardColor(p),
                      hidden: model.settings.hiddenCardWindows(p))
            .frame(maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text("Nothing on the dashboard").font(.brand(12)).foregroundStyle(theme.secondary)
            Button("Choose what to show", action: onEdit)
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .block(.neutral)
    }
}

/// One provider on the dashboard: what's left of its main window big, the next one as a bar.
struct DashboardTile: View {
    let provider: ProviderID
    let state: LimitState
    /// Window shown big, the same one its Usage card shows.
    let primary: LimitWindow?
    let color: CardColor
    /// Window ids the user switched off on the card.
    var hidden: Set<String> = []

    @Environment(\.colorScheme) private var scheme

    private var ink: Color { Theme(scheme).ink(color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let limits = state.limits, let primary {
                let second = secondary(limits, primary: primary)
                BigPercent(value: primary.left, size: 30, color: ink).padding(.top, 10)
                HStack(spacing: 3) {
                    warning(primary)
                    Text(caption(primary))
                }
                .font(.brand(11))
                .opacity(0.75)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if let second {
                    HStack(spacing: 3) {
                        warning(second)
                        Text(second.label).opacity(0.75)
                        Spacer(minLength: 4)
                        Text("\(second.left)%").font(.brand(11, .bold)).monospacedDigit()
                            .contentTransition(.numericText(value: Double(second.left)))
                            .animation(.snappy(duration: 0.3), value: second.left)
                    }
                    .font(.brand(11))
                    .lineLimit(1)
                    .padding(.top, 8)
                    RemainingBar(fraction: Double(second.left) / 100, ink: ink).padding(.top, 4)
                }
            } else if state.limits == nil {
                skeleton
            } else {
                Text("No limits reported").font(.brand(11)).opacity(0.75).padding(.top, 10)
            }
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: .infinity, alignment: .topLeading)
        .block(color.tokens.fill)
        // Outside `block`, so the background sees it.
        .environment(\.blockLevel, primary.map { Double($0.left) / 100 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.name)
        .accessibilityValue(accessibilityValue)
    }

    private var header: some View {
        HStack(spacing: 5) {
            ProviderGlyph(provider: provider, size: 12, color: ink)
            Text(provider.name).font(.brand(12, .bold))
            Spacer(minLength: 2)
            if case .failed(let message, _) = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .opacity(0.7)
                    .hoverTip(message)
            }
        }
        .lineLimit(1)
    }

    /// The next window the card lists, preferring a full window over a narrow one.
    private func secondary(_ limits: ProviderLimits, primary: LimitWindow) -> LimitWindow? {
        let others = LimitWindow.cardSecondaries(limits.windows, primary: primary, hidden: hidden)
        return others.first { !$0.minor } ?? others.first
    }

    private func caption(_ w: LimitWindow) -> String {
        let reset = Format.reset(w.resetsAt)
        return reset.isEmpty ? w.label : "\(w.label) · \(reset)"
    }

    @ViewBuilder
    private func warning(_ w: LimitWindow) -> some View {
        if MenuBarImage.Level(w.percent) != .normal {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10, weight: .semibold))
        }
    }

    /// Same footprint as the loaded tile, so nothing jumps when limits arrive.
    private var skeleton: some View {
        Pulse {
            VStack(alignment: .leading, spacing: 6) {
                Bento.pill.fill(ink.opacity(0.22)).frame(width: 58, height: 28)
                Bento.pill.fill(ink.opacity(0.16)).frame(width: 70, height: 9)
                Spacer(minLength: 8)
                Bento.pill.fill(ink.opacity(0.16)).frame(maxWidth: .infinity).frame(height: 4)
            }
        }
        .padding(.top, 10)
    }

    private var accessibilityValue: String {
        guard let limits = state.limits else { return "Loading" }
        guard let primary else { return "No limits reported" }
        var parts = ["\(primary.label) \(primary.left)% left"]
        if let second = secondary(limits, primary: primary) { parts.append("\(second.label) \(second.left)% left") }
        return parts.joined(separator: ", ")
    }
}

/// CPU, memory and disk side by side on one block.
struct DashboardSystem: View {
    let snapshot: SystemSnapshot
    let stats: [DashboardStat]

    @Environment(\.colorScheme) private var scheme

    private var theme: Theme { Theme(scheme) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element) { i, stat in
                if i > 0 {
                    Rectangle().fill(theme.hairline).frame(width: 1).padding(.horizontal, 10)
                }
                column(stat)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(theme.text)
        .block(.neutral)
    }

    private func column(_ stat: DashboardStat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text(stat == .disk ? "Disk free" : stat.title)
                if level(stat) != .normal {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.brand(11))
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
            if let fraction = fraction(stat) {
                value(stat).padding(.top, 4)
                RemainingBar(fraction: fraction, ink: theme.text).padding(.top, 6)
            } else {
                Pulse {
                    VStack(alignment: .leading, spacing: 8) {
                        Bento.pill.fill(theme.text.opacity(0.14)).frame(width: 48, height: 20)
                        Bento.pill.fill(theme.text.opacity(0.1)).frame(maxWidth: .infinity).frame(height: 4)
                    }
                }
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.title)
        .accessibilityValue(accessibilityValue(stat))
    }

    @ViewBuilder
    private func value(_ stat: DashboardStat) -> some View {
        switch stat {
        case .cpu:
            BigPercent(value: Int((snapshot.cpu ?? 0).rounded()), size: 22, color: theme.text)
        case .memory:
            let (used, _) = Format.memoryParts(snapshot.memory?.used ?? 0)
            let (total, unit) = Format.memoryParts(snapshot.memory?.total ?? 0)
            BigValue(number: used, unit: "/ \(total) \(unit)", size: 22, color: theme.text)
        case .disk:
            let (number, unit) = Format.bytesParts(snapshot.disk?.free ?? 0)
            BigValue(number: number, unit: unit, size: 22, color: theme.text)
        }
    }

    /// How full the bar is: busy CPU, used memory, used disk. Nil until the first reading.
    private func fraction(_ stat: DashboardStat) -> Double? {
        switch stat {
        case .cpu: snapshot.cpu.map { $0 / 100 }
        case .memory: snapshot.memory.map { Double($0.used) / Double(max($0.total, 1)) }
        case .disk: snapshot.disk.map { Double($0.used) / Double(max($0.total, 1)) }
        }
    }

    private func level(_ stat: DashboardStat) -> MenuBarImage.Level {
        switch stat {
        case .cpu: .normal
        case .memory: snapshot.memory.map { MenuBarImage.Level($0.pressure) } ?? .normal
        case .disk: snapshot.disk.map { MenuBarImage.Level(free: $0.free) } ?? .normal
        }
    }

    private func accessibilityValue(_ stat: DashboardStat) -> String {
        switch stat {
        case .cpu: snapshot.cpu.map { "\(Int($0.rounded()))% busy" } ?? "Loading"
        case .memory: snapshot.memory.map { "\(Format.memory($0.used)) of \(Format.memory($0.total)) used" } ?? "Loading"
        case .disk: snapshot.disk.map { "\(Format.bytes($0.free)) free of \(Format.bytes($0.total))" } ?? "Loading"
        }
    }
}
