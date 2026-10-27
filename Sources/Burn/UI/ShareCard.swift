import AppKit
import SwiftUI

/// A shareable image of the period's spend, drawn in the same bento style as the popover.
/// Always light, so it looks the same wherever it's pasted.
struct ShareCard: View {
    let usage: UsageSummary

    static let size = CGSize(width: 600, height: 340)
    private let theme = Theme(.light)

    private var split: [(ProviderID, Double)] {
        ProviderID.allCases.compactMap { p in usage.byProvider[p].flatMap { $0 > 0 ? (p, $0) : nil } }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                total
                // A single provider would only repeat the total.
                if split.count > 1 {
                    VStack(spacing: 8) {
                        ForEach(split, id: \.0) { providerSpend($0.0, cost: $0.1) }
                    }
                    .frame(width: 196)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "flame.fill").font(.system(size: 11, weight: .semibold))
                Text("Burn").font(.brand(12, .bold))
                Spacer()
                Text("github.com/noyex/burn").font(.brand(12))
            }
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 6)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(theme.base)
        .environment(\.colorScheme, .light)
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Burned at API prices").font(.brand(15, .bold))
            Text(split.count == 1 ? "\(periodPhrase) · \(split[0].0.name)" : periodPhrase)
                .font(.brand(13))
                .opacity(0.65)
            Spacer(minLength: 8)
            Text(Format.money(usage.cost))
                .font(.brand(72, .display))
                .kerning(-2.2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("\(Format.tokens(usage.tokens)) tokens").font(.brand(13)).opacity(0.7)
            SpendBars(usage: usage, ink: Theme.limeInk, animated: false)
                .frame(height: 52)
                .padding(.top, 14)
        }
        .foregroundStyle(Theme.limeInk)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.lime, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func providerSpend(_ p: ProviderID, cost: Double) -> some View {
        let ink = theme.ink(p)
        let share = usage.cost > 0 ? Int((cost / usage.cost * 100).rounded()) : 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProviderGlyph(provider: p, size: 14, color: ink)
                Text(p.name).font(.brand(14, .bold))
            }
            Spacer(minLength: 6)
            Text(Format.money(cost))
                .font(.brand(32, .display))
                .kerning(-0.9)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(share)% of spend").font(.brand(12)).opacity(0.75)
        }
        .foregroundStyle(ink)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.fill(p), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var periodPhrase: String {
        switch usage.period {
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .all:
            guard let first = usage.buckets.first?.start else { return "All time" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "MMMM yyyy"
            return "Since \(f.string(from: first))"
        }
    }

    /// Renders the card at 2x and puts it on the clipboard as PNG. Returns false if rendering failed.
    @MainActor
    static func copy(_ usage: UsageSummary) -> Bool {
        let renderer = ImageRenderer(content: ShareCard(usage: usage))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        // Keeps the Shelf from saving Burn's own image as a screenshot.
        item.setData(Data(), forType: ShelfStore.ownType)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
}
