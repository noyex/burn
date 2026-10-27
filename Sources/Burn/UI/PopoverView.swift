import SwiftUI

struct PopoverView: View {
    let model: AppModel
    @State private var showingSettings = false
    @State private var selection: Set<URL> = []
    @State private var confirmingClear = false
    @State private var copiedSelection = false
    @State private var copiedShare = false
    @State private var hoveringShare = false
    @State private var resetTasks: [String: Task<Void, Never>] = [:]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: Theme { Theme(scheme) }
    private var expanded: Bool { !showingSettings && model.settings.tab == .shelf && model.settings.shelfExpanded }
    /// Width of the blocks; the panel adds room for their shadows around it.
    private var width: CGFloat { expanded ? 644 : 304 }

    var body: some View {
        let visible = model.popoverVisible
        Group {
            if showingSettings {
                SettingsView(model: model) { showingSettings = false }
                    .block(theme.surface)
            } else {
                main
            }
        }
        .frame(width: width)
        // Nearly invisible, but catches clicks in the gaps between blocks so they don't
        // fall through to the window below and close the panel.
        .background(Color.black.opacity(0.001))
        .padding(Bento.shadowInset)
        .foregroundStyle(theme.text)
        // Grows out of the menu bar icon; only animates in, the panel fades itself out.
        .scaleEffect(visible || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(visible ? 1 : 0)
        .animation(visible ? .easeOut(duration: 0.2) : nil, value: visible)
    }

    private var main: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: Bento.gap) {
            HStack(spacing: Bento.gap) {
                IconSwitcher(selection: $settings.tab)
                Spacer()
                if settings.tab == .shelf { expandButton }
            }
            .padding(.bottom, 2)
            // Stacked, so the outgoing tab fades out in place while the new one fades in.
            ZStack(alignment: .top) {
                switch settings.tab {
                case .usage:
                    VStack(alignment: .leading, spacing: Bento.gap) { usage }
                        .transition(tabTransition)
                case .shelf:
                    ShelfView(shelf: model.shelf, width: width,
                              columns: expanded ? 4 : 2, maxHeight: expanded ? 560 : 380,
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
    }

    private var tabTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }

    private var expandButton: some View {
        let expanded = model.settings.shelfExpanded
        return RoundIconButton(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: expanded ? "Make shelf smaller" : "Make shelf bigger", size: 36, floating: true) {
            withAnimation(.snappy(duration: 0.25)) { model.settings.shelfExpanded.toggle() }
        }
    }

    // MARK: Usage

    /// Providers with limits (or still loading) get colored blocks; the rest a compact row each.
    private var blockProviders: [ProviderID] {
        model.connected.filter { p in
            switch model.limits[p] ?? .loading {
            case .loading, .loaded: true
            case .failed(_, let last): last != nil
            case .signedOut: false
            }
        }
    }

    @ViewBuilder
    private var usage: some View {
        let visible = model.popoverVisible
        if model.connected.isEmpty {
            signIn.reveal(visible, index: 0)
        } else {
            let blocks = blockProviders
            let issues = model.connected.filter { !blocks.contains($0) }
            if let hero = blocks.first {
                providerBlock(hero, hero: true).reveal(visible, index: 0)
            }
            let rest = Array(blocks.dropFirst())
            ForEach(Array(stride(from: 0, to: rest.count, by: 2)), id: \.self) { i in
                HStack(spacing: Bento.gap) {
                    providerBlock(rest[i], hero: false)
                    if i + 1 < rest.count { providerBlock(rest[i + 1], hero: false) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .reveal(visible, index: 1 + i / 2)
            }
            ForEach(issues) { p in
                ProviderIssueRow(provider: p, state: model.limits[p] ?? .loading)
                    .reveal(visible, index: blocks.count)
            }
        }
        if model.hasUsage {
            SpendBlock(model: model).reveal(visible, index: 3)
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

    private func providerBlock(_ p: ProviderID, hero: Bool) -> some View {
        ProviderBlock(provider: p, state: model.limits[p] ?? .loading,
                      primary: model.limits[p]?.limits.flatMap { model.menuBarWindow(for: $0) }, hero: hero)
            .frame(maxHeight: .infinity)
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
        HStack(spacing: Bento.gap) {
            switch model.settings.tab {
            case .usage:
                syncStatus
                if let usage = model.usage, usage.cost > 0 { shareButton(usage) }
            case .shelf: shelfActions
            }
            // Kept out of the way while screenshots are selected, the footer is full then.
            if let release = model.updater.available, model.settings.tab == .usage || selection.isEmpty {
                updateButton(release)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }
            RoundIconButton(systemName: "gearshape", label: "Settings") { showingSettings = true }
        }
        .font(.brand(11))
        .padding(4)
        .floating(theme.surface, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: model.updater.available)
    }

    private func updateButton(_ release: Updater.Release) -> some View {
        let installing = model.updater.state == .installing
        return Button(installing ? "Updating…" : "Update") { model.updater.install() }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(installing)
            .help("Update to Burn \(release.version)")
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
        .help("Copy an image of your spend")
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
