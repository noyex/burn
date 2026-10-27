import SwiftUI

/// One provider's card and account, opened from the provider list in settings.
struct ProviderSettingsView: View {
    let model: AppModel
    let provider: ProviderID
    let onBack: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var theme: Theme { Theme(scheme) }

    var body: some View {
        let p = provider
        VStack(alignment: .leading, spacing: Bento.gap) {
            HStack(spacing: 10) {
                RoundIconButton(systemName: "chevron.left", label: "Back", action: onBack)
                ProviderGlyph(provider: p, color: theme.text)
                Text(p.name).font(.brand(14, .bold))
            }
            .padding(.bottom, 4)

            SettingsSectionTitle("CARD")
            SettingsGroup {
                HStack {
                    Text("Show in panel")
                    Spacer()
                    Toggle("Show in panel", isOn: Binding(
                        get: { model.settings.showsInPanel(p) },
                        set: { on in withAnimation(.snappy(duration: 0.25)) { model.settings.setShowsInPanel(p, on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .frame(height: 32)
                Divider().opacity(0.6)
                HStack {
                    Text("Size")
                    Spacer()
                    PillSegmented(options: CardSize.allCases, selection: Binding(
                        get: { model.cardSize(p) },
                        set: { model.settings.setCardSize(p, $0, cards: model.cardProviders) }),
                                  style: .segmented(theme), compact: true, accessibilityLabel: "Size") { $0.title }
                }
                .frame(height: 32)
                Divider().opacity(0.6)
                HStack {
                    Text("Color")
                    Spacer()
                    swatches
                }
                .frame(height: 32)
                mainNumberRow
            }
            if model.settings.panelLayout != .custom {
                Text("Sizes apply to the Custom layout. Changing one switches the panel to Custom.")
                    .font(.brand(11))
                    .foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            SettingsSectionTitle("ACCOUNT")
            SettingsGroup {
                HStack {
                    Text("Plan")
                    Spacer()
                    Text(model.limits[p]?.limits?.plan ?? "Unknown").foregroundStyle(theme.secondary)
                }
                .frame(height: 32)
                Divider().opacity(0.6)
                accountRow
            }
        }
    }

    private var swatches: some View {
        let selected = model.settings.cardColor(provider)
        return HStack(spacing: 6) {
            ForEach(CardColor.allCases) { c in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.settings.setCardColor(provider, c) }
                } label: {
                    Circle().fill(theme.fill(c))
                        .overlay { Circle().strokeBorder(theme.hairline, lineWidth: 0.5) }
                        .overlay {
                            if c == selected {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.ink(c))
                            }
                        }
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .overlay { if c == selected { Circle().strokeBorder(theme.text.opacity(0.5), lineWidth: 1.5) } }
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .hoverTip(c.title)
                .accessibilityLabel(c.title)
                .accessibilityAddTraits(c == selected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var mainNumberRow: some View {
        let windows = model.limits[provider]?.limits?.windows ?? []
        if windows.count > 1 {
            Divider().opacity(0.6)
            HStack {
                Text("Main number")
                Spacer()
                Picker("Main number", selection: Binding(
                    get: {
                        let id = model.settings.cardWindow(provider)
                        return windows.contains { $0.id == id } ? id : Settings.highest
                    },
                    set: { model.settings.setCardWindow(provider, $0) })) {
                    Text("Highest").tag(Settings.highest)
                    ForEach(windows) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            .frame(height: 32)
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        let p = provider
        let signedIn: Bool = {
            guard model.connected.contains(p) else { return false }
            if case .signedOut = model.limits[p] { return false }
            return true
        }()
        HStack(spacing: 8) {
            if signedIn {
                Text("Status")
                Spacer()
                Text("Signed in").foregroundStyle(theme.secondary)
            } else {
                Text("Sign in")
                Spacer()
                CommandChip(command: p.loginCommand)
            }
        }
        .frame(height: 32)
    }
}
