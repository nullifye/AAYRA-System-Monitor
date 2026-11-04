import Foundation

enum Format {
    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        fraction.formatted(.percent.precision(.fractionLength(digits)))
    }

    static func bytes<T: BinaryInteger>(_ value: T) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory, spellsOutZero: false))
    }

    static func diskBytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    /// Short disk size for tight rows: "204 GB", "2.7 GB", "1.2 TB" (decimal units, like Finder).
    static func diskShort(_ value: Int64) -> String {
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        let v = Double(max(0, value))
        for (scale, unit) in units where v >= scale {
            let n = v / scale
            return (n >= 100 ? String(format: "%.0f", n) : String(format: "%.1f", n)) + " " + unit
        }
        return "\(Int(v)) B"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = Int64(max(0, bytesPerSecond))
        return value.formatted(.byteCount(style: .decimal, spellsOutZero: false)) + "/s"
    }

    static func minutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// "1y 9m", "4m", "12d" — rough age for things like battery packs.
    static func age(since date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date, to: Date())
        let y = parts.year ?? 0, m = parts.month ?? 0, d = parts.day ?? 0
        if y > 0 { return m > 0 ? "\(y)y \(m)m" : "\(y)y" }
        if m > 0 { return "\(m)m" }
        return "\(d)d"
    }

    static func uptime(since date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        let d = seconds / 86_400, h = (seconds % 86_400) / 3_600, m = (seconds % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private static let temperatureFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitStyle = .short
        f.numberFormatter.maximumFractionDigits = 1
        return f   // converts °C to °F automatically for regions that use it
    }()

    static func temperature(celsius: Double) -> String {
        temperatureFormatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }
}

extension String {
    /// "up 3h" → "Up 3h"
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
