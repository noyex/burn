import Foundation

/// How provider cards are sized in the usage panel.
enum PanelLayout: String, CaseIterable, Sendable {
    case auto, grid, list, custom

    var title: String { rawValue.capitalized }

    /// Size of each card, in the order the cards are shown. `custom` gives the size saved per provider.
    func sizes(for cards: [ProviderID], custom: (ProviderID) -> CardSize) -> [ProviderID: CardSize] {
        Dictionary(uniqueKeysWithValues: cards.enumerated().map { i, p in
            let size: CardSize = switch self {
            case .custom: custom(p)
            case .grid: .m
            case .list: .s
            case .auto: cards.count == 1 ? .l : cards.count == 2 ? .m : i == 0 ? .l : .s
            }
            return (p, size)
        })
    }
}

enum PanelOrder: String, CaseIterable, Sendable {
    case manual, closestToLimit

    var title: String {
        switch self {
        case .manual: "Manual"
        case .closestToLimit: "Closest to limit"
        }
    }
}

/// L spans the width with the other windows on the right, M takes half a row, S is one compact row.
enum CardSize: String, CaseIterable, Sendable {
    case s, m, l

    var title: String { rawValue.uppercased() }
}

enum PanelArrangement {
    /// Rows of cards: two M cards in a row share it, everything else gets a row of its own.
    static func rows(_ cards: [ProviderID], sizes: [ProviderID: CardSize]) -> [[ProviderID]] {
        var rows: [[ProviderID]] = []
        for p in cards {
            if sizes[p] == .m, let last = rows.last, last.count == 1, sizes[last[0]] == .m {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows
    }

    /// Least left first; providers without a number keep their manual order after the rest.
    static func closestToLimit(_ providers: [ProviderID], remaining: (ProviderID) -> Double?) -> [ProviderID] {
        let known = providers.compactMap { p in remaining(p).map { (p, $0) } }
        let sorted = known.enumerated()
            .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset }
            .map(\.element.0)
        return sorted + providers.filter { !sorted.contains($0) }
    }

    /// Puts `visible` into the slots the visible providers held in `order`, so hidden ones keep their place.
    static func merge(_ visible: [ProviderID], into order: [ProviderID]) -> [ProviderID] {
        var next = visible.makeIterator()
        let merged = order.map { visible.contains($0) ? next.next() ?? $0 : $0 }
        return merged + visible.filter { !merged.contains($0) }
    }

    /// Saved order, dropping unknown ids and adding providers it doesn't know yet.
    static func order(from saved: [String]) -> [ProviderID] {
        var order: [ProviderID] = []
        for p in saved.compactMap(ProviderID.init(rawValue:)) where !order.contains(p) { order.append(p) }
        return order + ProviderID.allCases.filter { !order.contains($0) }
    }
}
