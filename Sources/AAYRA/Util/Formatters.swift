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

    /// Short memory size for tight rows: "5.9 GB", "812 MB" (binary units, like Activity Monitor).
    static func memoryShort<T: BinaryInteger>(_ value: T) -> String {
        let bytes = Double(Int64(clamping: value))
        let gb = bytes / 1_073_741_824
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", bytes / 1_048_576)
    }

    /// Short rate for the menu bar: "830 B/s", "45 KB/s", "1.2 MB/s" (decimal units, like `rate`).
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        switch v {
        case ..<1_000: return "\(Int(v)) B/s"
        case ..<1_000_000: return String(format: "%.0f KB/s", v / 1_000)
        case ..<10_000_000_000: return String(format: "%.1f MB/s", v / 1_000_000)
        default: return String(format: "%.1f GB/s", v / 1_000_000_000)
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = Int64(max(0, bytesPerSecond))
        return value.formatted(.byteCount(style: .decimal, spellsOutZero: false)) + "/s"
    }

    /// Length of a chart's time window: "1 min", "2 min", "90 s".
    static func span(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 && s % 60 == 0 ? "\(s / 60) min" : "\(s) s"
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

    private static let fixedTemperatureFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitStyle = .short
        f.unitOptions = .providedUnit
        f.numberFormatter.maximumFractionDigits = 1
        return f
    }()

    /// Follows the Temperature setting: the region's unit, or always °C / °F.
    static func temperature(celsius: Double) -> String {
        let value = Measurement(value: celsius, unit: UnitTemperature.celsius)
        switch AppSettings.temperatureUnit {
        case .system: return temperatureFormatter.string(from: value)
        case .celsius: return fixedTemperatureFormatter.string(from: value)
        case .fahrenheit: return fixedTemperatureFormatter.string(from: value.converted(to: .fahrenheit))
        }
    }
}

extension String {
    /// "up 3h" → "Up 3h"
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
