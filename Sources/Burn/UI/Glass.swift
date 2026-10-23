import SwiftUI

/// Liquid Glass on macOS 26+, the closest material look on older systems.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.quinary, in: shape)
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Round glass button with an SF Symbol.
struct GlassIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .glass(in: Circle(), interactive: true)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A segmented control whose selection slides between options on a glass track.
struct GlassSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
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
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if selected {
                        Capsule()
                            .fill(.primary.opacity(0.14))
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .glass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}
