import SwiftUI

/// The see-through canvas the window gives the content, and where the menu bar icon sits along
/// it. The content hangs centered under the icon and moves itself when its width changes.
@MainActor @Observable
final class PanelCanvas {
    /// Room for the widest and tallest the content can get; the window never resizes while open.
    static let maxSize = CGSize(width: PopoverView.expandedWidth + Bento.shadowInset.leading + Bento.shadowInset.trailing,
                                height: 800)
    var width = maxSize.width
    var anchorX = maxSize.width / 2
}

struct PopoverView: View {
    let model: AppModel
    let canvas: PanelCanvas
    @State private var showingSettings = false
    @State private var selection: Set<URL> = []
    @State private var confirmingClear = false
    @State private var copiedSelection = false
    @State private var copiedShare = false
    @State private var hoveringShare = false
    @State private var resetTasks: [String: Task<Void, Never>] = [:]
    @State private var cardFrames: [ProviderID: CGRect] = [:]
    @State private var dragging: ProviderID?
    @State private var dragLocation: CGPoint = .zero
    @State private var grabOffset: CGSize = .zero
    @State private var lastSwap: ProviderID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: Theme { Theme(scheme) }
    private static let usageWidth: CGFloat = 304
    static let expandedWidth: CGFloat = 644
    /// Doesn't depend on the tab, so the shelf keeps its grid while it fades out.
    private var shelfWidth: CGFloat { model.settings.shelfExpanded ? Self.expandedWidth : Self.usageWidth }
    /// Width of the blocks; the panel adds room for their shadows around it.
    private var width: CGFloat { !showingSettings && model.settings.tab == .shelf ? shelfWidth : Self.usageWidth }
    /// Left edge of the content on the canvas: centered under the icon, kept on screen. Comes
    /// from the same state as `width`, so the two animate in step.
    private var contentX: CGFloat {
        let total = width + Bento.shadowInset.leading + Bento.shadowInset.trailing
        return min(max(canvas.anchorX - total / 2, 0), max(canvas.width - total, 0))
    }

    var body: some View {
        let visible = model.popoverVisible
        ZStack(alignment: .topLeading) {
            if showingSettings {
                SettingsView(model: model) {
                    withAnimation(.snappy(duration: 0.25)) { showingSettings = false }
                } onArrange: {
                    withAnimation(.snappy(duration: 0.25)) {
                        showingSettings = false
                        model.settings.tab = .usage
                        model.editingPanel = true
                    }
                }
                .block(theme.surface)
                .transition(tabTransition)
            } else {
                main.transition(tabTransition)
            }
        }
        .frame(width: width)
        // Nearly invisible, but catches clicks in the gaps between blocks so they don't
        // fall through to the window below and close the panel.
        .background(Color.black.opacity(0.001))
        .padding(Bento.shadowInset)
        .fixedSize(horizontal: false, vertical: true)
        .hoverTipHost()
        .foregroundStyle(theme.text)
        // Grows out of the menu bar icon; only animates in, the panel fades itself out.
        .scaleEffect(visible || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(visible ? 1 : 0)
        .animation(visible ? .easeOut(duration: 0.2) : nil, value: visible)
        .offset(x: contentX)
        // Under Reduce Motion the content changes place and size without sliding there.
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: contentX)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var main: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: Bento.gap) {
            HStack(spacing: Bento.gap) {
                IconSwitcher(selection: $settings.tab)
                Spacer()
                if settings.tab == .shelf {
                    expandButton.transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.bottom, 2)
            // Stacked, so the outgoing tab fades out in place while the new one fades in. Only the
            // incoming tab counts toward the layout, so the footer glides straight to where it ends.
            ZStack(alignment: .topLeading) {
                switch settings.tab {
                case .usage:
                    VStack(alignment: .leading, spacing: Bento.gap) { usage }
                        .frame(width: Self.usageWidth)
                        .transition(tabTransition)
                case .shelf:
                    ShelfView(shelf: model.shelf, width: shelfWidth,
                              columns: settings.shelfExpanded ? 4 : 2, maxHeight: settings.shelfExpanded ? 560 : 380,
                              selection: $selection)
                        .transition(tabTransition)
                }
            }
            footer.padding(.top, 2)
        }
        .onChange(of: model.shelf.items) { _, items in
            // Pruned or cleared screenshots must not stay selected.
            selection.formIntersection(items.map(\.id))
        }
        .onChange(of: settings.tab) { _, tab in
            if tab != .usage { model.editingPanel = false }
        }
        .onChange(of: model.editingPanel) { _, editing in
            if !editing { dragging = nil }
        }
    }

    /// The new view settles in while the old one gets out of the way quickly, so they don't
    /// pile up on each other.
    private var tabTransition: AnyTransition {
        .asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                    removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    private var expandButton: some View {
        let expanded = model.settings.shelfExpanded
        return RoundIconButton(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: expanded ? "Make shelf smaller" : "Make shelf bigger", size: 36, floating: true) {
            withAnimation(.snappy(duration: 0.25)) { model.settings.shelfExpanded.toggle() }
        }
    }

    // MARK: Usage

    @ViewBuilder
    private var usage: some View {
        let visible = model.popoverVisible
        let editing = model.editingPanel
        let shown = model.panelProviders
        let cards = shown.filter(model.hasCard)
        let issues = shown.filter { !cards.contains($0) }
        let sizes = model.settings.cardSizes(for: cards)
        let rows = PanelArrangement.rows(cards, sizes: sizes)
        if model.connected.isEmpty {
            signIn.reveal(visible, index: 0)
        } else {
            if !cards.isEmpty {
                CardGrid(rows: rows) {
                    ForEach(cards) { p in
                        card(p, size: sizes[p] ?? .m)
                            .reveal(visible, index: rows.firstIndex { $0.contains(p) } ?? 0)
                            .layoutValue(key: CardID.self, value: p)
                    }
                }
                .coordinateSpace(name: Self.cardSpace)
                .onPreferenceChange(CardFrameKey.self) { frames in
                    MainActor.assumeIsolated { cardFrames = frames }
                }
                .overlay(alignment: .topLeading) { draggedCard(sizes: sizes) }
                .zIndex(dragging == nil ? 0 : 1)
            }
            ForEach(issues) { p in
                ProviderIssueRow(provider: p, state: model.limits[p] ?? .loading)
                    .allowsHitTesting(!editing)
                    .editChrome(editing, title: p.name, size: nil) { hide(p) }
                    .wiggle(editing, seed: seed(p), amplitude: 0.35)
                    .reveal(visible, index: rows.count)
            }
        }
        if model.settings.showsSpending {
            spend
                .allowsHitTesting(!editing)
                .startsEditing { startEditing() }
                .editChrome(editing, title: "Spent", size: nil) {
                    withAnimation(.snappy(duration: 0.25)) { model.settings.showsSpending = false }
                }
                .wiggle(editing, seed: 5.3, amplitude: 0.35)
                .reveal(visible, index: rows.count + 1)
        }
        if editing {
            hiddenCards.transition(.opacity)
        } else if !model.connected.isEmpty, shown.isEmpty, !spendShown {
            emptyPanel.reveal(visible, index: 0)
        }
    }

    @ViewBuilder
    private var spend: some View {
        if model.hasUsage {
            SpendBlock(model: model)
        } else if let pct = model.importPercent {
            ProgressView(value: Double(pct), total: 100) {
                Text("Importing usage from Claude Code and Codex logs…").font(.brand(11))
            }
            .tint(Theme.limeInk)
            .controlSize(.small)
            .foregroundStyle(Theme.limeInk)
            .block(Theme.lime)
        }
    }

    private var spendShown: Bool { model.settings.showsSpending && (model.hasUsage || model.importPercent != nil) }

    private func card(_ p: ProviderID, size: CardSize) -> some View {
        let editing = model.editingPanel
        let lifted = dragging == p
        return providerBlock(p, size: size)
            .opacity(lifted ? 0 : 1)
            // Keeps the gap visible and the drag's view hit-testable while the copy follows the pointer.
            .background { if lifted { Bento.blockShape.fill(theme.text.opacity(0.06)) } }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: CardFrameKey.self, value: [p: geo.frame(in: .named(Self.cardSpace))])
                }
            }
            .gesture(reorderGesture(p), including: editing ? .all : .subviews)
            .startsEditing { startEditing() }
            .editChrome(editing && !lifted, title: p.name, size: Binding(
                get: { size },
                set: { new in
                    withAnimation(.snappy(duration: 0.25)) {
                        model.settings.setCardSize(p, new, cards: model.cardProviders)
                    }
                })) { hide(p) }
            .wiggle(editing && !lifted, seed: seed(p), amplitude: size == .m ? 0.6 : 0.35)
    }

    private func providerBlock(_ p: ProviderID, size: CardSize) -> some View {
        ProviderBlock(provider: p, state: model.limits[p] ?? .loading,
                      primary: model.limits[p]?.limits.flatMap { model.cardWindow(for: $0) },
                      size: size, color: model.settings.cardColor(p))
            .frame(maxHeight: .infinity)
    }

    /// Different phases, so the cards don't rock in lockstep.
    private func seed(_ p: ProviderID) -> Double { Double(ProviderID.allCases.firstIndex(of: p) ?? 0) * 1.9 }

    // MARK: Editing

    private static let cardSpace = "cards"

    private func startEditing() {
        guard !model.editingPanel else { return }
        withAnimation(.snappy(duration: 0.25)) { model.editingPanel = true }
    }

    private func hide(_ p: ProviderID) {
        withAnimation(.snappy(duration: 0.25)) { model.settings.setShowsInPanel(p, false) }
    }

    /// Follows the pointer with a copy of the card while the card itself leaves a gap that moves
    /// to whichever card the pointer is over.
    private func reorderGesture(_ p: ProviderID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.cardSpace))
            .onChanged { g in
                if dragging != p {
                    let frame = cardFrames[p] ?? .zero
                    grabOffset = CGSize(width: g.startLocation.x - frame.minX, height: g.startLocation.y - frame.minY)
                    lastSwap = nil
                    withAnimation(.easeOut(duration: 0.12)) { dragging = p }
                }
                dragLocation = g.location
                let cards = model.cardProviders
                guard let target = cards.first(where: { $0 != p && cardFrames[$0]?.contains(g.location) == true }) else {
                    lastSwap = nil
                    return
                }
                // Once per card entered, so a card that changes size on the move can't flip back and forth.
                guard target != lastSwap, let from = cards.firstIndex(of: p), let to = cards.firstIndex(of: target) else { return }
                lastSwap = target
                var next = cards
                next.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
                withAnimation(.snappy(duration: 0.25)) { model.settings.reorder(next) }
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.25)) { dragging = nil }
            }
    }

    @ViewBuilder
    private func draggedCard(sizes: [ProviderID: CardSize]) -> some View {
        if let p = dragging, let frame = cardFrames[p] {
            providerBlock(p, size: sizes[p] ?? .m)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(1.03)
                .offset(x: dragLocation.x - grabOffset.width, y: dragLocation.y - grabOffset.height)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// What's hidden from the panel, each one a button that brings it back.
    @ViewBuilder
    private var hiddenCards: some View {
        let providers = model.settings.providerOrder.filter { model.connected.contains($0) && !model.settings.showsInPanel($0) }
        if !providers.isEmpty || !model.settings.showsSpending {
            HStack(spacing: Bento.gap) {
                ForEach(providers) { p in
                    addButton(p.name) { model.settings.setShowsInPanel(p, true) }
                }
                if !model.settings.showsSpending {
                    addButton("Spent") { model.settings.showsSpending = true }
                }
            }
        }
    }

    private func addButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text(title).font(.brand(12, .bold))
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .floating(theme.surface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Show \(title)")
    }

    private var emptyPanel: some View {
        VStack(spacing: 10) {
            Text("Everything is hidden from the panel").font(.brand(12)).foregroundStyle(theme.secondary)
            Button("Edit panel") { startEditing() }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .block(theme.neutral)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to a provider in Terminal:")
                .font(.brand(12))
                .foregroundStyle(theme.secondary)
            ForEach(ProviderID.allCases) { p in
                HStack(spacing: 8) {
                    ProviderGlyph(provider: p, color: theme.text)
                    CommandChip(command: p.loginCommand)
                }
            }
        }
        .block(theme.neutral)
    }

    // MARK: Footer

    private var footer: some View {
        let onUsage = model.settings.tab == .usage
        let editing = model.editingPanel
        return HStack(spacing: Bento.gap) {
            // The rows stay in the tree and crossfade: a row that was inserted or removed would
            // not ride along while the footer slides to the other tab's height.
            ZStack(alignment: .leading) {
                HStack(spacing: Bento.gap) {
                    syncStatus
                    if let usage = model.usage, usage.cost > 0 { shareButton(usage) }
                }
                .footerRow(shown: onUsage && !editing)
                HStack(spacing: Bento.gap) { shelfActions }
                    .footerRow(shown: !onUsage)
                HStack(spacing: Bento.gap) {
                    Text("Drag to reorder").foregroundStyle(theme.secondary).padding(.leading, 8)
                    Spacer()
                    Button("Done") { withAnimation(.snappy(duration: 0.25)) { model.editingPanel = false } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
                .footerRow(shown: onUsage && editing)
            }
            if let release = updateShown {
                updateButton(release)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }
            if !editing {
                RoundIconButton(systemName: "gearshape", label: "Settings") {
                    withAnimation(.snappy(duration: 0.25)) { showingSettings = true }
                }
                .transition(.opacity)
            }
        }
        .font(.brand(11))
        .padding(4)
        .floating(theme.surface, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: updateShown)
    }

    /// Kept out of the way while screenshots are selected or cards are arranged, the footer is full then.
    private var updateShown: Updater.Release? {
        guard !model.editingPanel else { return nil }
        return model.settings.tab == .usage || selection.isEmpty ? model.updater.available : nil
    }

    private func updateButton(_ release: Updater.Release) -> some View {
        let installing = model.updater.state == .installing
        return Button(installing ? "Updating…" : "Update") { model.updater.install() }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(installing)
            .hoverTip("Update to Burn \(release.version)")
    }

    private var syncStatus: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(model.syncing ? "Syncing…" : Format.synced(model.lastSync, now: ctx.date))
                    .opacity(model.hasUsage ? 1 : 0)
            }
            .foregroundStyle(theme.secondary)
            .padding(.leading, 8)
            Spacer()
        }
    }

    /// Copies an image of the period's spend; morphs into "Copied" for a moment.
    private func shareButton(_ usage: UsageSummary) -> some View {
        Button {
            guard ShareCard.copy(usage) else { return }
            withAnimation(.snappy(duration: 0.25)) { copiedShare = true }
            resetLater("share", after: 1.4) {
                withAnimation(.easeOut(duration: 0.25)) { copiedShare = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copiedShare ? "checkmark" : "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .offset(y: copiedShare ? 0 : -1)
                    .contentTransition(.symbolEffect(.replace))
                if copiedShare {
                    Text("Copied").font(.brand(11, .bold))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .foregroundStyle(copiedShare ? theme.text : theme.secondary)
            .padding(.horizontal, copiedShare ? 10 : 0)
            .frame(minWidth: 28, minHeight: 28)
            .background(hoveringShare ? theme.neutralHover : theme.neutral, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hoveringShare = h } }
        .hoverTip("Copy an image of your spend")
        .accessibilityLabel(copiedShare ? "Copied" : "Copy an image of your spend")
    }

    @ViewBuilder
    private var shelfActions: some View {
        let items = model.shelf.items
        let selected = items.filter { selection.contains($0.id) }
        if selected.isEmpty {
            Spacer()
            if !items.isEmpty {
                Button(confirmingClear ? "Clear all?" : "Clear") {
                    if confirmingClear {
                        confirmingClear = false
                        withAnimation(.snappy) { model.shelf.clear() }
                    } else {
                        confirmingClear = true
                        resetLater("clear", after: 3) { confirmingClear = false }
                    }
                }
                .buttonStyle(PillButtonStyle(destructive: confirmingClear))
            }
        } else {
            Text("\(selected.count) selected").foregroundStyle(theme.secondary).padding(.leading, 8)
            Spacer()
            Button("Deselect") { selection = [] }
                .buttonStyle(PillButtonStyle())
            Button {
                model.shelf.copy(selected)
                copiedSelection = true
                resetLater("copied", after: 1.2) { copiedSelection = false }
            } label: {
                Text(copiedSelection ? "Copied" : "Copy \(selected.count)")
                    .frame(minWidth: 56)
            }
            .buttonStyle(PillButtonStyle(prominent: true))
        }
    }

    /// Runs `reset` after a delay, replacing a pending reset with the same key.
    private func resetLater(_ key: String, after seconds: Double, _ reset: @escaping @MainActor () -> Void) {
        resetTasks[key]?.cancel()
        resetTasks[key] = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { reset() }
        }
    }
}

private extension View {
    /// Fades a footer row in with the tab switch and out ahead of it, so the two don't pile up.
    func footerRow(shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .animation(shown ? .snappy(duration: 0.25) : .easeOut(duration: 0.12), value: shown)
            .allowsHitTesting(shown)
            .disabled(!shown)
            .accessibilityHidden(!shown)
    }
}
