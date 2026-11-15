import AppKit
import SwiftUI

/// Picks a theme by its colors. The panel shows next to this page, so a pick is seen at once.
struct ThemeSettingsView: View {
    let onBack: () -> Void
    /// The prompt just copied, to confirm it on its button.
    @State private var copiedPrompt: String?
    @Environment(\.colorScheme) private var scheme

    private var theme: Theme { Theme(scheme) }
    private var store: ThemeStore { ThemeStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Bento.gap) {
            HStack(spacing: 10) {
                RoundIconButton(systemName: "chevron.left", label: "Back", action: onBack)
                Text("Theme").font(.brand(14, .bold))
            }
            .padding(.bottom, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Bento.gap), count: 4), spacing: Bento.gap) {
                tile(id: nil, title: "Default", look: .standard)
                ForEach(store.available) { tile(id: $0.id, title: $0.title, look: $0.look) }
            }
            if let issue = store.issues.first {
                Text(issue)
                    .font(.brand(11))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            askAgent.padding(.top, 6)
            Button(copiedPrompt == ThemeStore.ideasPrompt ? "Copied. Paste it to your agent" : "No idea? Ask for a few designs") {
                copy(ThemeStore.ideasPrompt)
            }
            .buttonStyle(.plain)
            .font(.brand(11))
            .foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
            .hoverTip("Copies a prompt: your agent designs four themes to pick from")

            SettingsGroup {
                Button { store.openFolder() } label: {
                    HStack {
                        Text("Open themes folder")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
                    }
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tile(id: String?, title: String, look: ResolvedTheme) -> some View {
        let selected = store.selected == id
        return Button {
            store.select(id)
        } label: {
            VStack(spacing: 7) {
                ThemeOrb(colors: look.swatch(dark: scheme == .dark))
                    .frame(width: 32, height: 32)
                    .padding(3)
                    .overlay { if selected { Circle().strokeBorder(theme.text, lineWidth: 1.5) } }
                Text(title)
                    .font(.brand(10, selected ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(theme.neutral, in: Bento.smallShape)
            .contentShape(Bento.smallShape)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The main action: one big pill with the agents it works with.
    private var askAgent: some View {
        let copied = copiedPrompt == ThemeStore.agentPrompt
        return Button { copy(ThemeStore.agentPrompt) } label: {
            HStack(spacing: 10) {
                HStack(spacing: -7) {
                    ForEach(ProviderID.allCases) { p in
                        ProviderGlyph(provider: p, size: 13, color: theme.ink(p))
                            .frame(width: 24, height: 24)
                            .background(theme.fill(p), in: Circle())
                            // Cuts each badge out of the one under it.
                            .overlay { Circle().strokeBorder(theme.text, lineWidth: 1.5) }
                    }
                }
                Text(copied ? "Copied. Paste it to your agent" : "Ask your agent")
                    .font(.brand(13, .bold))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.base)
            .padding(.leading, 9)
            .padding(.trailing, 14)
            .frame(height: 42)
            .background(theme.text, in: Bento.pill)
            .contentShape(Bento.pill)
        }
        .buttonStyle(PressStyle())
        .hoverTip("Copies a prompt. Paste it to Claude Code, Codex or Cursor and say what you want")
        .accessibilityLabel("Copy a prompt that asks your agent for a theme")
    }

    private func copy(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copiedPrompt = prompt }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if copiedPrompt == prompt { withAnimation(.easeOut(duration: 0.15)) { copiedPrompt = nil } }
        }
    }
}

/// A theme at a glance: its main fill with two of its other colors glowing through.
private struct ThemeOrb: View {
    let colors: [RGBA]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width
            ZStack {
                Circle().fill(color(0))
                glow(color(1), at: UnitPoint(x: 0.3, y: 0.28), radius: size * 0.6)
                glow(color(2), at: UnitPoint(x: 0.74, y: 0.8), radius: size * 0.55)
            }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Theme(scheme).hairline, lineWidth: 0.5) }
        }
    }

    private func color(_ index: Int) -> Color { Color(colors[min(index, colors.count - 1)]) }

    private func glow(_ color: Color, at center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [color, color.opacity(0)], center: center, startRadius: 0, endRadius: radius)
    }
}
