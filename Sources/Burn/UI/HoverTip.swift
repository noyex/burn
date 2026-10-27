import SwiftUI

// AppKit tooltips (`.help`) never show here: the panel is non-activating and macOS only
// shows tooltips for the active app. So hovered views report a tip and its bounds up the
// tree, and the panel root draws one bubble above everything, unclipped by the blocks.

struct HoverTipValue {
    let text: String
    let anchor: Anchor<CGRect>
}

struct HoverTipKey: PreferenceKey {
    static let defaultValue: HoverTipValue? = nil
    static func reduce(value: inout HoverTipValue?, nextValue: () -> HoverTipValue?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Shows `text` in a bubble while the pointer rests on the view.
    func hoverTip(_ text: String) -> some View {
        modifier(HoverTipModifier(text: text))
    }

    /// Reports an already resolved tip, e.g. for the hovered part of a chart.
    func hoverTip(_ text: String?, isShown: Bool) -> some View {
        anchorPreference(key: HoverTipKey.self, value: .bounds) { anchor in
            guard isShown, let text, !text.isEmpty else { return nil }
            return HoverTipValue(text: text, anchor: anchor)
        }
    }

    /// Draws the hovered tip; apply once at the root of the panel.
    func hoverTipHost() -> some View {
        overlayPreferenceValue(HoverTipKey.self) { tip in
            GeometryReader { geo in
                if let tip {
                    TipPlacement(target: geo[tip.anchor]) {
                        TipBubble(text: tip.text)
                    }
                    .id(tip.text)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct HoverTipModifier: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hovering in
                pending?.cancel()
                guard hovering else { shown = false; return }
                // A short rest before showing, so sweeping across the panel doesn't flash tips.
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { shown = true }
                }
            }
            .onDisappear { pending?.cancel(); shown = false }
            .hoverTip(text, isShown: shown)
    }
}

private struct TipBubble: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Text(text)
            .font(.brand(11))
            .foregroundStyle(theme.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .floating(theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Centers the bubble above `target`, or below it when there's no room, kept inside the panel.
private struct TipPlacement: Layout {
    let target: CGRect
    private let gap: CGFloat = 6
    private let margin: CGFloat = 8
    private let maxWidth: CGFloat = 240

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let width = min(maxWidth, bounds.width - margin * 2)
        let ideal = bubble.sizeThatFits(.init(width: nil, height: nil))
        let size = ideal.width <= width ? ideal : bubble.sizeThatFits(.init(width: width, height: nil))
        let x = min(max(target.midX - size.width / 2, margin), bounds.width - margin - size.width)
        let above = target.minY - gap - size.height
        let y = above >= 0 ? above : target.maxY + gap
        bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                     proposal: .init(size))
    }
}
