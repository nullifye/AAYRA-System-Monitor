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

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = Int64(max(0, bytesPerSecond))
        return value.formatted(.byteCount(style: .decimal, spellsOutZero: false)) + "/s"
    }

    static func minutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
