import Foundation

enum Format {
    private static let en = Locale(identifier: "en_US")

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = en
        f.maximumFractionDigits = v >= 100 ? 0 : 2
        f.minimumFractionDigits = v >= 100 ? 0 : 2
        return f.string(from: v as NSNumber) ?? "$\(Int(v))"
    }

    static func tokens(_ v: Int64) -> String {
        let d = Double(v)
        switch d {
        case 1e9...: return String(format: "%.1fB", d / 1e9)
        case 1e6...: return String(format: "%.0fM", d / 1e6)
        case 1e3...: return String(format: "%.0fK", d / 1e3)
        default: return "\(v)"
        }
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// "2h 10m" within a day, weekday within a week, otherwise "1 Nov".
    static func reset(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        let f = DateFormatter()
        f.locale = en
        f.dateFormat = s < 6 * 86400 ? "EEE" : "d MMM"
        return f.string(from: date)
    }

    /// Compact form for the menu bar: "3h", "45m", "Mon".
    static func shortReset(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return reset(date, now: now)
    }

    static func synced(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Not synced yet" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "Synced just now" }
        if s < 3600 { return "Synced \(Int(s / 60)) min ago" }
        return "Synced \(Int(s / 3600)) h ago"
    }
}
