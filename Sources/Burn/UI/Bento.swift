import SwiftUI

/// Shared building blocks of the bento look.
enum Bento {
    static let blockRadius: CGFloat = 14
    static let gap: CGFloat = 6
    static let blockShape = RoundedRectangle(cornerRadius: blockRadius, style: .continuous)
    /// Room around the panel's content for the blocks' shadows.
    static let shadowInset = EdgeInsets(top: 6, leading: 14, bottom: 18, trailing: 14)
}

extension View {
    /// A solid bento block floating over the desktop.
    func block(_ fill: Color, padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floating(fill, in: Bento.blockShape)
    }

    /// Fills `shape` and lifts it off the desktop with a soft shadow.
    func floating<S: InsettableShape>(_ fill: Color, in shape: S) -> some View {
        modifier(Floating(fill: fill, shape: shape))
    }

    /// Fades and lifts the view in when the popover opens, staggered by `index`.
    func reveal(_ visible: Bool, index: Int) -> some View {
        modifier(Reveal(visible: visible, index: index))
    }
}

private struct Floating<S: InsettableShape>: ViewModifier {
    let fill: Color
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = Theme(scheme)
        content.background {
            shape.fill(fill)
                .overlay { shape.strokeBorder(theme.hairline, lineWidth: 0.5) }
                .shadow(color: theme.shadow, radius: 10, y: 4)
        }
    }
}

private struct Reveal: ViewModifier {
    let visible: Bool
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 6)
            // Only animate in; hiding happens after the popover is gone.
            .animation(visible ? .easeOut(duration: 0.22).delay(Double(index) * 0.03) : nil, value: visible)
    }
}

/// Segmented pills whose selection slides between options.
struct PillSegmented<Value: Hashable>: View {
    struct Style {
        let track: Color
        let selected: Color
        let selectedText: Color
        let text: Color
    }

    let options: [Value]
    @Binding var selection: Value
    let style: Style
    var compact = false
    var accessibilityLabel = ""
    let label: (Value) -> String

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.brand(compact ? 11 : 12, selected ? .bold : .medium))
                        .foregroundStyle(selected ? style.selectedText : style.text)
                        .padding(.horizontal, compact ? 8 : 0)
                        .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 22 : 26)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if selected {
                        Capsule()
                            .fill(style.selected)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(style.track, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Dark capsule of icon tabs whose highlight slides between them.
struct IconSwitcher: View {
    @Binding var selection: PopoverTab

    @Environment(\.colorScheme) private var scheme
    @Namespace private var namespace

    var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 0) {
            ForEach(PopoverTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                        .frame(width: 40, height: 30)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .floating(theme.switcher, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }
}

/// Round button with an SF Symbol on a neutral fill.
struct RoundIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 28
    /// Sits on its own over the desktop instead of on a surface.
    var floating = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let theme = Theme(scheme)
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(hovering ? theme.text : theme.secondary)
                .frame(width: size, height: size)
                .background {
                    if floating {
                        Color.clear.floating(hovering ? theme.neutral : theme.surface, in: Circle())
                    } else {
                        Circle().fill(hovering ? theme.neutralHover : theme.neutral)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Capsule text button: neutral, or filled with the text color when prominent.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = Theme(scheme)
        configuration.label
            .font(.brand(12, prominent ? .bold : .medium))
            .foregroundStyle(prominent ? theme.base : destructive ? .red : theme.text)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(prominent ? theme.text : theme.neutral, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Subtle press feedback for custom-drawn buttons.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
