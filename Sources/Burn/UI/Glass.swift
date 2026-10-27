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
}
