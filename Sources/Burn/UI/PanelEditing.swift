import AppKit
import SwiftUI

/// Lays provider cards out in rows: two M cards share a row and match heights, L and S cards and
/// a lone M take the full width. One flat layout, so cards slide when they change rows.
struct CardGrid: Layout {
    let rows: [[ProviderID]]
    var spacing = Bento.gap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 304
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in zip(indexedRows(subviews), heights) {
            let width = row.count > 1 ? (bounds.width - spacing) / 2 : bounds.width
            for (i, view) in row.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (width + spacing), y: y), anchor: .topLeading,
                           proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + spacing
        }
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        indexedRows(subviews).map { row in
            let w = row.count > 1 ? (width - spacing) / 2 : width
            return row.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
        }
    }

    /// Subviews grouped like `rows`, matched by their `CardID`.
    private func indexedRows(_ subviews: Subviews) -> [[LayoutSubview]] {
        let byID = Dictionary(subviews.map { ($0[CardID.self], $0) }, uniquingKeysWith: { a, _ in a })
        return rows.map { $0.compactMap { byID[$0] } }.filter { !$0.isEmpty }
    }
}

struct CardID: LayoutValueKey {
    static let defaultValue: ProviderID? = nil
}

/// Frames of the provider cards in the grid's coordinate space, for dragging.
struct CardFrameKey: PreferenceKey {
    static let defaultValue: [ProviderID: CGRect] = [:]
    static func reduce(value: inout [ProviderID: CGRect], nextValue: () -> [ProviderID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// A small rocking while the panel is being edited, like icons on a home screen.
    func wiggle(_ active: Bool, seed: Double, amplitude: Double = 0.6) -> some View {
        modifier(Wiggle(active: active, seed: seed, amplitude: amplitude))
    }

    /// Holding the card or right clicking it starts editing the panel.
    func startsEditing(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in action() })
            .onRightClick(action)
    }

    /// Runs `action` on a right click, without taking left clicks or hover from the view.
    func onRightClick(_ action: @escaping () -> Void) -> some View {
        background(RightClickCatcher(action: action))
    }

    /// The remove button and, for provider cards, the size switch shown on a card while editing.
    func editChrome(_ editing: Bool, title: String, size: Binding<CardSize>?, onRemove: @escaping () -> Void) -> some View {
        modifier(EditChrome(editing: editing, title: title, size: size, onRemove: onRemove))
    }
}

private struct Wiggle: ViewModifier {
    let active: Bool
    let seed: Double
    let amplitude: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let on = active && !reduceMotion
        // Always in the tree, so starting and stopping doesn't reset the card's own state.
        TimelineView(.animation(paused: !on)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            content.rotationEffect(.degrees(on ? sin(t * 18 + seed) * amplitude : 0))
        }
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickView { RightClickView() }
    func updateNSView(_ view: RightClickView, context: Context) { view.action = action }
}

/// Sits behind the SwiftUI content, which gets every event first, so it watches the window's
/// right clicks instead and claims those inside its bounds.
final class RightClickView: NSView {
    var action: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            let window = event.window
            let location = event.locationInWindow
            let claimed = MainActor.assumeIsolated {
                guard let self, let window, window === self.window,
                      self.bounds.contains(self.convert(location, from: nil)) else { return false }
                self.action?()
                return true
            }
            return claimed ? nil : event
        }
    }
}

private struct EditChrome: ViewModifier {
    let editing: Bool
    let title: String
    let size: Binding<CardSize>?
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = Theme(scheme)
        content
            .overlay(alignment: .topLeading) {
                if editing {
                    Button(action: onRemove) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.text)
                            .frame(width: 20, height: 20)
                            .floating(theme.surface, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .offset(x: -6, y: -6)
                    .hoverTip("Hide \(title)")
                    .accessibilityLabel("Hide \(title)")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if editing, let size {
                    PillSegmented(options: CardSize.allCases, selection: size,
                                  style: .init(track: theme.surface, selected: theme.text,
                                               selectedText: theme.base, text: theme.secondary),
                                  compact: true, accessibilityLabel: "\(title) size") { $0.title }
                        .shadow(color: theme.shadow, radius: 6, y: 2)
                        .padding(6)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomTrailing)))
                }
            }
    }
}
