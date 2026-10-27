import AppKit
import SwiftUI

/// Grid of copied screenshots. Click copies that screenshot, the corner circle or ⌘-click selects, dragging drops files anywhere.
struct ShelfView: View {
    let shelf: ShelfStore
    let width: CGFloat
    let columns: Int
    let maxHeight: CGFloat
    @Binding var selection: Set<URL>

    private let spacing: CGFloat = 8
    private var tileWidth: CGFloat { (width - spacing * CGFloat(columns - 1)) / CGFloat(columns) }
    private var tileHeight: CGFloat { (tileWidth * 0.625).rounded() }

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Screenshots you copy show up here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("⌃⇧⌘4")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            let rows = (shelf.items.count + columns - 1) / columns
            let contentHeight = CGFloat(rows) * (tileHeight + spacing) - spacing
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: columns),
                          spacing: spacing) {
                    ForEach(shelf.items) { item in
                        ShelfTile(item: item, size: CGSize(width: tileWidth, height: tileHeight),
                                  selected: selection.contains(item.id),
                                  selecting: !selection.isEmpty,
                                  actions: actions(for: item))
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(width: width, height: min(contentHeight, maxHeight))
        }
    }

    private func actions(for item: ShelfItem) -> ShelfTile.Actions {
        // Acting on a selected tile acts on the whole selection.
        let group = { selection.contains(item.id) ? shelf.items.filter { selection.contains($0.id) } : [item] }
        return ShelfTile.Actions(
            toggle: { selection.formSymmetricDifference([item.id]) },
            copy: { shelf.copy(group()) },
            copyOne: { shelf.copy([item]) },
            open: { NSWorkspace.shared.open(item.url) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting(group().map(\.url)) },
            delete: {
                let doomed = group()
                selection.subtract(doomed.map(\.id))
                withAnimation(.snappy) { shelf.delete(doomed) }
            },
            dragURLs: {
                let urls = group().map(\.url)
                return [item.url] + urls.filter { $0 != item.url }
            },
            groupCount: { group().count })
    }
}

private struct ShelfTile: View {
    struct Actions {
        let toggle: () -> Void
        let copy: () -> Void
        let copyOne: () -> Void
        let open: () -> Void
        let reveal: () -> Void
        let delete: () -> Void
        let dragURLs: () -> [URL]
        let groupCount: () -> Int
    }

    let item: ShelfItem
    let size: CGSize
    let selected: Bool
    let selecting: Bool
    let actions: Actions

    @State private var image: NSImage?
    @State private var hovering = false
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    private static let checkbox: CGFloat = 26
    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
            } else {
                Rectangle().fill(.quinary)
            }
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .glass(in: Capsule())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.12)),
                               lineWidth: selected ? 2.5 : 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if selected || hovering || selecting {
                checkmark.padding(6)
            }
        }
        .scaleEffect(hovering && !selected ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.18), value: selected)
        .overlay {
            TileInteraction(handlers: handlers, checkboxSize: Self.checkbox)
        }
        .task(id: item.url) { image = await Thumbnails.load(item.url) }
        .accessibilityElement()
        .accessibilityLabel(item.url.deletingPathExtension().lastPathComponent)
        .accessibilityAddTraits(selected ? [.isImage, .isSelected] : .isImage)
        .accessibilityAction(named: "Copy", actions.copy)
        .accessibilityAction(named: selected ? "Deselect" : "Select", actions.toggle)
        .accessibilityAction(named: "Delete", actions.delete)
    }

    private var checkmark: some View {
        ZStack {
            Circle().fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.black.opacity(0.25)))
            Circle().strokeBorder(.white.opacity(selected ? 0 : 0.9), lineWidth: 1.5)
            if selected {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
        .shadow(color: .black.opacity(0.3), radius: 2)
        .allowsHitTesting(false)
    }

    private var handlers: TileInteraction.Handlers {
        TileInteraction.Handlers(
            click: { inCheckbox, modifiers in
                if inCheckbox || modifiers.contains(.command) {
                    actions.toggle()
                } else {
                    actions.copyOne()
                    flashCopied()
                }
            },
            doubleClick: actions.open,
            hover: { hovering = $0 },
            dragURLs: actions.dragURLs,
            menu: menu)
    }

    private func menu() -> NSMenu {
        let n = actions.groupCount()
        let suffix = n > 1 ? " \(n) Screenshots" : ""
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Copy" + suffix) { actions.copy() })
        if n == 1 { menu.addItem(ClosureMenuItem("Open") { actions.open() }) }
        menu.addItem(ClosureMenuItem("Show in Finder") { actions.reveal() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete" + suffix) { actions.delete() })
        return menu
    }

    private func flashCopied() {
        withAnimation(.snappy(duration: 0.2)) { copied = true }
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}
