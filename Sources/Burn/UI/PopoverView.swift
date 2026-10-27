import SwiftUI

struct PopoverView: View {
    let model: AppModel
    @State private var showingSettings = false
    @State private var selection: Set<URL> = []
    @State private var confirmingClear = false
    @State private var copiedSelection = false
    @State private var resetTasks: [String: Task<Void, Never>] = [:]
    @Environment(\.colorScheme) private var scheme

    private static let padding: CGFloat = 8
    private var theme: Theme { Theme(scheme) }
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
        .background(theme.base)
        .foregroundStyle(theme.text)
    }

    private var main: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: Bento.gap) {
            HStack(spacing: Bento.gap) {
                PillSegmented(options: PopoverTab.allCases, selection: $settings.tab,
                              style: .init(track: theme.neutral, selected: theme.raised,
                                           selectedText: theme.text, text: theme.secondary),
                              accessibilityLabel: "View") { $0.title }
                if settings.tab == .shelf { expandButton }
            }
            .padding(.bottom, 2)
            switch settings.tab {
            case .usage: usage
            case .shelf:
                ShelfView(shelf: model.shelf, width: width - Self.padding * 2,
                          columns: expanded ? 4 : 2, maxHeight: expanded ? 560 : 380,
                          selection: $selection)
            }
            footer.padding(.top, 2)
        }
        .onChange(of: model.shelf.items) { _, items in
            // Pruned or cleared screenshots must not stay selected.
            selection.formIntersection(items.map(\.id))
        }
    }

    private var expandButton: some View {
        let expanded = model.settings.shelfExpanded
        return RoundIconButton(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: expanded ? "Make shelf smaller" : "Make shelf bigger", size: 30) {
            model.settings.shelfExpanded.toggle()
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
                      primaryID: model.limits[p]?.limits.flatMap { model.menuBarWindow(for: $0)?.id }, hero: hero)
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
            case .usage: syncStatus
            case .shelf: shelfActions
            }
            RoundIconButton(systemName: "gearshape", label: "Settings") { showingSettings = true }
        }
        .font(.brand(11))
    }

    private var syncStatus: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(model.syncing ? "Syncing…" : Format.synced(model.lastSync, now: ctx.date))
                    .opacity(model.hasUsage ? 1 : 0)
            }
            .foregroundStyle(theme.secondary)
            .padding(.leading, 4)
            Spacer()
        }
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
            Text("\(selected.count) selected").foregroundStyle(theme.secondary).padding(.leading, 4)
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
