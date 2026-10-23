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

            Text("MENU BAR").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            group {
                ForEach(Array(model.connected.enumerated()), id: \.element) { i, p in
                    if i > 0 { Divider() }
                    providerRow(p)
                }
            }

            group {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.settings.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(height: 32)
            }

            Button("Quit Burn") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.leading, 4)
        }
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
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
                    get: { model.settings.menuBarWindow(p) },
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
