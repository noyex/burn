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

    /// Share of a limit still left, from its used percent.
    static func remaining(_ used: Double) -> String { percent(min(max(100 - used, 0), 100)) }

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

    /// Decimal units, like Finder: "182 GB", "8.4 GB", "1.2 TB", "640 MB".
    static func bytes<T: BinaryInteger>(_ v: T) -> String {
        let (number, unit) = bytesParts(v)
        return "\(number) \(unit)"
    }

    /// `bytes` split into the number and its unit, for a big number with a small unit.
    static func bytesParts<T: BinaryInteger>(_ v: T) -> (String, String) {
        let d = Double(v)
        let (value, unit): (Double, String) = switch d {
        case 1e12...: (d / 1e12, "TB")
        case 1e9...: (d / 1e9, "GB")
        case 1e6...: (d / 1e6, "MB")
        default: (d / 1e3, "KB")
        }
        // One decimal below 10, where it still says something.
        let text = value < 10 && value.rounded() != value
            ? String(format: "%.1f", locale: en, value) : String(Int(value.rounded()))
        return (text, unit)
    }

    /// "4.2 MB/s", "210 KB/s", "0 KB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1e3 ? "0 KB/s" : bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// "4h 10m", "45m".
    static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    static func synced(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Not synced yet" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "Synced just now" }
        if s < 3600 { return "Synced \(Int(s / 60)) min ago" }
        return "Synced \(Int(s / 3600)) h ago"
    }
}
