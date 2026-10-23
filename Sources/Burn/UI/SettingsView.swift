import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Text("Settings").font(.system(size: 13, weight: .semibold))
            }

            if !model.connected.isEmpty {
                sectionTitle("MENU BAR")
                group {
                    ForEach(Array(model.connected.enumerated()), id: \.element) { i, p in
                        if i > 0 { Divider() }
                        providerRow(p)
                    }
                }
            }

            sectionTitle("ACCOUNTS")
            group {
                ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { i, p in
                    if i > 0 { Divider() }
                    accountRow(p)
                }
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

            Button("Quit Burn") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.leading, 4)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func accountRow(_ p: ProviderID) -> some View {
        let signedIn: Bool = {
            guard model.connected.contains(p) else { return false }
            if case .signedOut = model.limits[p] { return false }
            return true
        }()
        HStack(spacing: 8) {
            ProviderGlyph(provider: p)
            Text(p.name)
            Spacer()
            if signedIn {
                Text("Signed in").font(.caption).foregroundStyle(.secondary)
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
            ProviderGlyph(provider: p)
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
