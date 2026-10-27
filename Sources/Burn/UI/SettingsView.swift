import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let onBack: () -> Void
    /// Closes settings and starts editing the panel.
    let onArrange: () -> Void
    @State private var provider: ProviderID?
    @State private var draggedRow: ProviderID?
    @State private var dragStart = 0
    @State private var dragTranslation: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: Theme { Theme(scheme) }
    /// A row plus the divider under it.
    private static let rowPitch: CGFloat = 33

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let provider {
                ProviderSettingsView(model: model, provider: provider) {
                    withAnimation(.snappy(duration: 0.25)) { self.provider = nil }
                }
                .transition(pageTransition)
            } else {
                list.transition(pageTransition)
            }
        }
    }

    private var pageTransition: AnyTransition {
        .asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                    removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Bento.gap) {
            HStack(spacing: 10) {
                RoundIconButton(systemName: "chevron.left", label: "Back", action: onBack)
                Text("Settings").font(.brand(14, .bold))
            }
            .padding(.bottom, 4)

            SettingsSectionTitle("PANEL")
            SettingsGroup { panelRows }

            SettingsSectionTitle("PROVIDERS")
            SettingsGroup {
                let order = model.orderedProviders
                ForEach(Array(order.enumerated()), id: \.element) { i, p in
                    if i > 0 { Divider().opacity(0.6) }
                    providerListRow(p)
                        .offset(y: draggedRow == p ? dragTranslation - CGFloat(i - dragStart) * Self.rowPitch : 0)
                        .zIndex(draggedRow == p ? 1 : 0)
                }
            }

            if !model.connected.isEmpty {
                SettingsSectionTitle("MENU BAR")
                SettingsGroup {
                    ForEach(Array(model.connected.enumerated()), id: \.element) { i, p in
                        if i > 0 { Divider().opacity(0.6) }
                        menuBarRow(p)
                    }
                }
            }

            SettingsSectionTitle("SHELF")
            SettingsGroup {
                HStack {
                    Text("Keep screenshots")
                    Spacer()
                    Picker("Keep screenshots", selection: Binding(
                        get: { model.settings.shelfRetentionDays },
                        set: { model.settings.shelfRetentionDays = $0; model.shelf.prune() })) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("Forever").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .controlSize(.small)
                }
                .frame(height: 32)
            }

            SettingsGroup {
                HStack {
                    Text("Launch at login")
                    Spacer()
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { model.settings.setLaunchAtLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .frame(height: 32)
            }

            HStack {
                Button("Quit Burn") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                Spacer()
                if Updater.current != "0.0.0" { Text("Burn \(Updater.current)") }
            }
            .foregroundStyle(theme.secondary)
            .font(.brand(11))
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var panelRows: some View {
        @Bindable var settings = model.settings
        HStack {
            Text("Layout")
            Spacer()
            PillSegmented(options: PanelLayout.allCases, selection: $settings.panelLayout,
                          style: .segmented(theme), compact: true, accessibilityLabel: "Layout") { $0.title }
        }
        .frame(height: 32)
        Divider().opacity(0.6)
        HStack {
            Text("Order")
            Spacer()
            Picker("Order", selection: $settings.panelOrder) {
                ForEach(PanelOrder.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
        }
        .frame(height: 32)
        Divider().opacity(0.6)
        HStack {
            Text("Show spending")
            Spacer()
            Toggle("Show spending", isOn: $settings.showsSpending)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(height: 32)
        Divider().opacity(0.6)
        Button(action: onArrange) {
            HStack {
                Text("Arrange in panel…")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func providerListRow(_ p: ProviderID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .frame(width: 16, height: 32)
                .contentShape(Rectangle())
                .gesture(rowDrag(p))
                .hoverTip("Drag to reorder")
                .accessibilityLabel("Reorder \(p.name)")
            HStack(spacing: 8) {
                ProviderGlyph(provider: p, color: theme.text)
                Text(p.name)
                Text(plan(p)).font(.brand(11)).foregroundStyle(theme.secondary).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { open(p) }
            Toggle("Show \(p.name) in panel", isOn: Binding(
                get: { model.settings.showsInPanel(p) },
                set: { model.settings.setShowsInPanel(p, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Button { open(p) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 16, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(p.name) settings")
        }
        .frame(height: 32)
        .background(theme.neutral)
    }

    private func plan(_ p: ProviderID) -> String {
        guard model.connected.contains(p) else { return "Not signed in" }
        if case .signedOut = model.limits[p] { return "Signed out" }
        return model.limits[p]?.limits?.plan ?? ""
    }

    private func open(_ p: ProviderID) {
        withAnimation(.snappy(duration: 0.25)) { provider = p }
    }

    /// Moves the row to wherever it's dragged; the order is saved as it changes.
    private func rowDrag(_ p: ProviderID) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let order = model.orderedProviders
                guard let current = order.firstIndex(of: p) else { return }
                if draggedRow != p {
                    draggedRow = p
                    dragStart = current
                }
                dragTranslation = g.translation.height
                let target = min(max(dragStart + Int((g.translation.height / Self.rowPitch).rounded()), 0), order.count - 1)
                guard target != current else { return }
                var next = order
                next.move(fromOffsets: [current], toOffset: target > current ? target + 1 : target)
                withAnimation(.snappy(duration: 0.2)) { model.settings.reorder(next) }
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) {
                    draggedRow = nil
                    dragTranslation = 0
                }
            }
    }

    @ViewBuilder
    private func menuBarRow(_ p: ProviderID) -> some View {
        let windows = model.limits[p]?.limits?.windows ?? []
        HStack(spacing: 8) {
            ProviderGlyph(provider: p, color: theme.text)
            Text(p.name)
            Spacer()
            if windows.count > 1 {
                Picker("Limit", selection: Binding(
                    get: {
                        let id = model.settings.menuBarWindow(p)
                        return windows.contains { $0.id == id } ? id : Settings.highest
                    },
                    set: { model.settings.setMenuBarWindow(p, $0); model.settingsChanged() })) {
                    Text("Highest").tag(Settings.highest)
                    ForEach(windows) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            Toggle("Show \(p.name) in menu bar", isOn: Binding(
                get: { model.settings.showsInMenuBar(p) },
                set: { model.settings.setShowsInMenuBar(p, $0); model.settingsChanged() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(height: 32)
    }
}

struct SettingsSectionTitle: View {
    let title: String
    @Environment(\.colorScheme) private var scheme

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.brand(10, .bold)).kerning(0.4).foregroundStyle(Theme(scheme).secondary)
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}

/// Rows on one neutral block.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) { content }
            .font(.brand(12))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Theme(scheme).neutral, in: Bento.blockShape)
    }
}

extension PillSegmented.Style {
    /// A raised pill on a neutral settings row.
    @MainActor static func segmented(_ theme: Theme) -> Self {
        .init(track: theme.text.opacity(0.06), selected: theme.raised, selectedText: theme.text, text: theme.secondary)
    }
}
