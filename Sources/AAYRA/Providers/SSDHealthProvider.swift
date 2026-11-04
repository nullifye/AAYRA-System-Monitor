import CNVMe

/// Health of the internal NVMe SSD, from its SMART / Health log.
struct SSDHealth: Equatable {
    var health: Double            // 0...1, i.e. 100 % minus the drive's own wear estimate
    var temperatureC: Double?
    var bytesWritten: UInt64
    var bytesRead: UInt64
    var powerOnHours: UInt64
    var powerCycles: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    var availableSpare: Int
    var hasCriticalWarning: Bool

    /// Plain-language summary in the spirit of Disk Utility's "Verified / Failing".
    var condition: String {
        if hasCriticalWarning || mediaErrors > 0 { return "Check Drive" }
        return health >= 0.5 ? "Good" : "Worn"
    }
}

enum SSDHealthProvider {
    /// NVMe "data units" are 1,000 × 512-byte blocks.
    private static let bytesPerDataUnit: UInt64 = 512_000

    static func sample() -> SSDHealth? {
        var raw = AAYRANVMeSMART()
        guard aayra_read_nvme_smart(&raw) == 1 else { return nil }
        let kelvin = Double(raw.temperatureKelvin)
        return SSDHealth(
            health: max(0, 1 - Double(raw.percentageUsed) / 100),
            temperatureC: kelvin > 0 ? kelvin - 273.15 : nil,
            bytesWritten: raw.dataUnitsWritten &* bytesPerDataUnit,
            bytesRead: raw.dataUnitsRead &* bytesPerDataUnit,
            powerOnHours: raw.powerOnHours,
            powerCycles: raw.powerCycles,
            unsafeShutdowns: raw.unsafeShutdowns,
            mediaErrors: raw.mediaErrors,
            availableSpare: Int(raw.availableSpare),
            hasCriticalWarning: raw.criticalWarning != 0
        )
    }
}
