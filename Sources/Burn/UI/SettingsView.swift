import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let onBack: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var theme: Theme { Theme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: Bento.gap) {
            HStack(spacing: 10) {
                RoundIconButton(systemName: "chevron.left", label: "Back", action: onBack)
                Text("Settings").font(.brand(14, .bold))
            }
            .padding(.bottom, 4)

            if !model.connected.isEmpty {
                sectionTitle("MENU BAR")
                group {
                    ForEach(Array(model.connected.enumerated()), id: \.element) { i, p in
                        if i > 0 { Divider().opacity(0.6) }
                        providerRow(p)
                    }
                }
            }

            sectionTitle("ACCOUNTS")
            group {
                ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { i, p in
                    if i > 0 { Divider().opacity(0.6) }
                    accountRow(p)
                }
            }

            sectionTitle("SHELF")
            group {
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

            group {
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
                Text("Burn \(Updater.current)")
            }
            .foregroundStyle(theme.secondary)
            .font(.brand(11))
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.brand(10, .bold)).kerning(0.4).foregroundStyle(theme.secondary)
            .padding(.leading, 4)
            .padding(.top, 6)
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .font(.brand(12))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(theme.neutral, in: Bento.blockShape)
    }

    @ViewBuilder
    private func accountRow(_ p: ProviderID) -> some View {
        let signedIn: Bool = {
            guard model.connected.contains(p) else { return false }
            if case .signedOut = model.limits[p] { return false }
            return true
        }()
        HStack(spacing: 8) {
            ProviderGlyph(provider: p, color: theme.text)
            Text(p.name)
            Spacer()
            if signedIn {
                Text("Signed in").font(.brand(11)).foregroundStyle(theme.secondary)
            } else {
                CommandChip(command: p.loginCommand)
            }
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderID) -> some View {
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
