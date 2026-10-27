import SwiftUI

// MARK: - Limits

/// Remaining share of a window, 0...100.
private func remaining(_ w: LimitWindow) -> Int { Int(min(max(100 - w.percent, 0), 100).rounded()) }

/// "66%" with a smaller percent sign.
struct BigPercent: View {
    let value: Int
    let size: CGFloat
    var color: Color

    var body: some View {
        (Text("\(value)").font(.brand(size, .display)) + Text("%").font(.brand(size * 0.5, .display)))
            .monospacedDigit()
            .kerning(-size * 0.03)
            .foregroundStyle(color)
            .contentTransition(.numericText(value: Double(value)))
            .animation(.snappy(duration: 0.3), value: value)
            .lineLimit(1)
    }
}

/// One provider as a solid block in its brand color. The hero block spans the full width
/// and lists the other windows on the right; small blocks list them below.
struct ProviderBlock: View {
    let provider: ProviderID
    let state: LimitState
    /// Window shown big; the one the menu bar shows.
    let primary: LimitWindow?
    let hero: Bool

    @Environment(\.colorScheme) private var scheme

    private var theme: Theme { Theme(scheme) }
    private var ink: Color { theme.ink(provider) }

    var body: some View {
        Group {
            if let limits = state.limits, let primary {
                content(limits, primary: primary)
            } else if let limits = state.limits {
                // Loaded but no windows reported: nothing to pulse for.
                header(plan: limits.plan, primary: nil)
            } else {
                skeleton
            }
        }
        .frame(maxWidth: .infinity, minHeight: hero ? 96 : 92, alignment: .topLeading)
        .block(theme.fill(provider))
        .accessibilityElement(children: .combine)
    }

    private func content(_ limits: ProviderLimits, primary: LimitWindow) -> some View {
        let others = limits.windows.filter { $0.id != primary.id }
        return VStack(alignment: .leading, spacing: 0) {
            header(plan: limits.plan, primary: primary)
            Spacer(minLength: 10)
            if hero {
                HStack(alignment: .bottom) {
                    primaryStack(primary, size: 52)
                    Spacer(minLength: 8)
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(others) { heroSecondary($0) }
                    }
                }
            } else {
                primaryStack(primary, size: 38)
                ForEach(others) { smallSecondary($0).padding(.top, 3) }
            }
        }
    }

    private func header(plan: String?, primary: LimitWindow?) -> some View {
        HStack(spacing: 5) {
            ProviderGlyph(provider: provider, size: 12, color: ink)
            Text(provider.name).font(.brand(12, .bold))
            if let plan { Text(plan).font(.brand(11)).opacity(0.65) }
            Spacer(minLength: 4)
            if case .failed(let message, _) = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .opacity(0.7)
                    .hoverTip(message)
                    .accessibilityLabel(message)
            }
            if let primary, MenuBarImage.Level(primary.percent) != .normal {
                alertPill(MenuBarImage.Level(primary.percent) == .full ? "Empty" : "Low", level: .init(primary.percent))
                    .hoverTip(alertTip(primary))
            }
        }
        .foregroundStyle(ink)
        .lineLimit(1)
    }

    private func primaryStack(_ w: LimitWindow, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            BigPercent(value: remaining(w), size: size, color: ink)
            Text(caption(w))
                .font(.brand(11))
                .foregroundStyle(ink.opacity(0.75))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name) \(w.label)")
        .accessibilityValue("\(remaining(w))% left, resets \(Format.reset(w.resetsAt))")
    }

    private func caption(_ w: LimitWindow) -> String {
        let reset = Format.reset(w.resetsAt)
        guard !reset.isEmpty else { return w.label }
        guard hero else { return "\(w.label) · \(reset)" }
        return w.resetsAt.map { (1..<86400).contains($0.timeIntervalSinceNow) } == true
            ? "\(w.label) · resets in \(reset)" : "\(w.label) · resets \(reset)"
    }

    private func heroSecondary(_ w: LimitWindow) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            label(w).font(.brand(11)).opacity(0.75)
            value(w, size: 22)
            Text(Format.reset(w.resetsAt)).font(.brand(11)).opacity(0.75)
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name) \(w.label)")
        .accessibilityValue("\(remaining(w))% left, resets \(Format.reset(w.resetsAt))")
    }

    private func smallSecondary(_ w: LimitWindow) -> some View {
        HStack(spacing: 4) {
            label(w).opacity(0.75)
            value(w, size: 11)
            let reset = Format.reset(w.resetsAt)
            if !reset.isEmpty { Text("· \(reset)").opacity(0.75) }
        }
        .font(.brand(11))
        .foregroundStyle(ink)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name) \(w.label)")
        .accessibilityValue("\(remaining(w))% left, resets \(Format.reset(w.resetsAt))")
    }

    /// A secondary label; low or empty ones get a warning glyph instead of a pill around the value.
    private func label(_ w: LimitWindow) -> some View {
        HStack(spacing: 3) {
            if MenuBarImage.Level(w.percent) != .normal {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10, weight: .semibold))
                    .hoverTip(alertTip(w))
            }
            Text(w.label)
        }
    }

    /// Why a window is flagged, and when it comes back.
    private func alertTip(_ w: LimitWindow) -> String {
        let reset = Format.reset(w.resetsAt)
        let state = MenuBarImage.Level(w.percent) == .full
            ? "\(w.label) limit used up"
            : "\(w.label) limit almost used up, \(remaining(w))% left"
        guard !reset.isEmpty else { return state }
        let soon = w.resetsAt.map { (1..<86400).contains($0.timeIntervalSinceNow) } == true
        return soon ? "\(state). Resets in \(reset)" : "\(state). Resets \(reset)"
    }

    private func value(_ w: LimitWindow, size: CGFloat) -> some View {
        Text("\(remaining(w))%").font(.brand(size, size > 14 ? .display : .bold)).monospacedDigit()
    }

    private func alertPill(_ title: String, level: MenuBarImage.Level) -> some View {
        Text(title).font(.brand(10, .bold))
            .foregroundStyle(theme.alert(level, on: provider))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(ink, in: Capsule())
    }

    /// Same footprint as the loaded block, so nothing jumps when limits arrive.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(plan: nil, primary: nil)
            Spacer(minLength: 10)
            Pulse {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(ink.opacity(0.22)).frame(width: hero ? 92 : 64, height: hero ? 40 : 30)
                    Capsule().fill(ink.opacity(0.16)).frame(width: 84, height: 9)
                }
            }
        }
        .accessibilityLabel("\(provider.name) loading")
    }
}

/// A provider that can't show limits: signed out, or failing with nothing cached.
struct ProviderIssueRow: View {
    let provider: ProviderID
    let state: LimitState

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 6) {
            ProviderGlyph(provider: provider, size: 12, color: theme.text)
            Text(provider.name).font(.brand(12, .bold)).foregroundStyle(theme.text)
            Spacer(minLength: 6)
            switch state {
            case .signedOut:
                CommandChip(command: provider.loginCommand)
                    .hoverTip("Signed out. Sign in again in Terminal")
            case .failed(let message, _):
                Text(message).font(.brand(11)).foregroundStyle(theme.secondary).lineLimit(1)
            default:
                EmptyView()
            }
        }
        .frame(minHeight: 26)
        .block(theme.neutral, padding: 10)
    }
}

/// Gently pulses placeholder content.
struct Pulse<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Spend

/// What the period's usage would have cost at API prices, on a lime block.
struct SpendBlock: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Spent")
                    .font(.brand(12, .bold))
                    .hoverTip("Estimated at API list prices")
                Spacer()
                PillSegmented(options: Period.allCases, selection: $model.period,
                              style: .init(track: Theme.limeInk.opacity(0.08), selected: Theme.limeInk,
                                           selectedText: Theme.lime, text: Theme.limeInk.opacity(0.7)),
                              compact: true, accessibilityLabel: "Period") { $0.title }
            }
            if let usage = model.usage {
                summary(usage)
            } else if let error = model.usageError {
                Text(error).font(.brand(11)).opacity(0.7).padding(.top, 10)
            } else {
                placeholder
            }
        }
        .foregroundStyle(Theme.limeInk)
        .block(Theme.lime)
    }

    @ViewBuilder
    private func summary(_ usage: UsageSummary) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(Format.money(usage.cost))
                .font(.brand(40, .display))
                .kerning(-1.2)
                .monospacedDigit()
                .contentTransition(.numericText(value: usage.cost))
                .animation(.snappy(duration: 0.3), value: usage.cost)
            Spacer()
            Text("\(Format.tokens(usage.tokens)) tokens").font(.brand(11)).opacity(0.7)
        }
        .padding(.top, 8)
        let split = ProviderID.allCases.compactMap { p in usage.byProvider[p].flatMap { $0 > 0 ? (p, $0) : nil } }
        if split.count > 1 {
            Text(split.map { "\($0.0.name) \(Format.money($0.1))" }.joined(separator: " · "))
                .font(.brand(11))
                .monospacedDigit()
                .opacity(0.7)
        }
        SpendBars(usage: usage, ink: Theme.limeInk)
            .id(usage.period)
            .frame(height: 38)
            .padding(.top, 10)
        HStack {
            Text(SpendBars.label(usage.buckets.first?.start, unit: usage.unit))
            Spacer()
            Text(usage.period == .today ? "now" : SpendBars.label(usage.buckets.last?.start, unit: usage.unit))
        }
        .font(.brand(10))
        .opacity(0.55)
        .padding(.top, 4)
    }

    private var placeholder: some View {
        Pulse {
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(Theme.limeInk.opacity(0.14)).frame(width: 120, height: 34)
                Capsule().fill(Theme.limeInk.opacity(0.1)).frame(maxWidth: .infinity).frame(height: 38)
            }
        }
        .padding(.top, 10)
    }
}

/// Stacked cost bars per bucket, one shade of `ink` per provider. Grows in from the baseline.
struct SpendBars: View {
    let usage: UsageSummary
    let ink: Color

    @State private var grown: Bool
    @State private var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `animated: false` draws the bars at full height right away, e.g. for an image render.
    init(usage: UsageSummary, ink: Color, animated: Bool = true) {
        self.usage = usage
        self.ink = ink
        _grown = State(initialValue: !animated)
    }

    private static let shades: [ProviderID: Double] = [.claude: 1, .codex: 0.45, .cursor: 0.25]

    var body: some View {
        GeometryReader { geo in
            let buckets = usage.buckets
            let peak = max(buckets.map(\.total).max() ?? 0, .leastNonzeroMagnitude)
            let slot = geo.size.width / CGFloat(max(buckets.count, 1))
            let spacing: CGFloat = slot > 6 ? 2 : slot > 3 ? 1 : 0
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(buckets) { b in
                    bar(b, peak: peak, height: geo.size.height)
                        .opacity(hovered == nil || hovered == b.id ? 1 : 0.45)
                        // The whole column, so the tip sits above the chart, not on the bar.
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .hoverTip(tip(b), isShown: hovered == b.id)
                }
            }
            // Keeps bars on the baseline even when the tallest is shorter than the frame (no spend).
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .scaleEffect(x: 1, y: grown ? 1 : 0.02, anchor: .bottom)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                var next: Date?
                if case .active(let p) = phase, !buckets.isEmpty {
                    next = buckets[min(max(Int(p.x / slot), 0), buckets.count - 1)].id
                }
                guard next != hovered else { return }
                withAnimation(.easeOut(duration: 0.15)) { hovered = next }
            }
        }
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true; return }
            withAnimation(.spring(duration: 0.4, bounce: 0)) { grown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cost per \(Self.unitName(usage.unit))")
        .accessibilityValue(peakDescription)
    }

    private func bar(_ b: UsageBucket, peak: Double, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(ProviderID.allCases.reversed()) { p in
                let cost = b.cost[p] ?? 0
                if cost > 0 {
                    Rectangle().fill(ink.opacity(Self.shades[p] ?? 1))
                        .frame(height: max(1, height * cost / peak))
                }
            }
            if b.total == 0 {
                Rectangle().fill(ink.opacity(0.15)).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5))
    }

    /// "Tue, 3 Mar\n$4.20 · Claude $3.00 · Codex $1.20"
    private func tip(_ b: UsageBucket) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        switch usage.unit {
        case .hour: f.dateFormat = "HH:mm"
        case .day: f.dateFormat = "EEE, d MMM"
        case .week: f.dateFormat = "'Week of' d MMM"
        }
        let split = ProviderID.allCases.compactMap { p in
            b.cost[p].flatMap { $0 > 0 ? "\(p.name) \(Format.money($0))" : nil }
        }
        let cost = split.count > 1 ? ([Format.money(b.total)] + split).joined(separator: " · ") : Format.money(b.total)
        return "\(f.string(from: b.start))\n\(cost)"
    }

    private var peakDescription: String {
        guard let peak = usage.buckets.max(by: { $0.total < $1.total }), peak.total > 0 else { return "No usage" }
        return "Peak \(Format.money(peak.total)) on \(Self.label(peak.start, unit: usage.unit))"
    }

    static func unitName(_ unit: BucketUnit) -> String {
        switch unit {
        case .hour: "hour"
        case .day: "day"
        case .week: "week"
        }
    }

    static func label(_ date: Date?, unit: BucketUnit) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        switch unit {
        case .hour: f.dateFormat = "HH:mm"
        case .day: f.dateFormat = "d MMM"
        case .week: f.dateFormat = "MMM yyyy"
        }
        return f.string(from: date)
    }
}
