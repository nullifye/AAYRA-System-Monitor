import Foundation
import IOKit
import IOKit.ps

struct BatteryStats: Equatable {
    enum State: Equatable { case charging, charged, onBattery, pluggedNotCharging }

    var charge: Double = 0                 // 0...1
    var state: State = .onBattery
    var minutesToEmpty: Int?               // nil while macOS is still calculating
    var minutesToFull: Int?
    var cycleCount: Int?
    var designCycles: Int?
    var temperatureC: Double?
    var currentCapacity_mAh: Int?
    var designCapacity_mAh: Int?
    var adapterWatts: Int?
    /// "Maximum Capacity" exactly as System Settings shows it (from system_profiler).
    var reportedHealth: Double?
    /// Fallback health computed from the gauge's nominal capacity vs design capacity.
    var computedHealth: Double? {
        guard let c = currentCapacity_mAh, let d = designCapacity_mAh, d > 0 else { return nil }
        return min(1, Double(c) / Double(d))
    }
    var health: Double? { reportedHealth ?? computedHealth }
    var condition: String?

    var isPluggedIn: Bool { state != .onBattery }
}

enum BatteryProvider {
    /// Returns nil on Macs without an internal battery.
    static func sample() -> BatteryStats? {
        guard var stats = powerSourceStats() else { return nil }
        mergeSmartBattery(into: &stats)
        return stats
    }

    // MARK: IOPowerSources (charge, state, time remaining)

    private static func powerSourceStats() -> BatteryStats? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            var s = BatteryStats()
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            s.charge = max > 0 ? Double(current) / Double(max) : 0

            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let charged = desc[kIOPSIsChargedKey] as? Bool ?? false
            s.state = !onAC ? .onBattery : charging ? .charging : (charged || current >= max) ? .charged : .pluggedNotCharging

            if let t = desc[kIOPSTimeToEmptyKey] as? Int, t > 0, !onAC { s.minutesToEmpty = t }
            if let t = desc[kIOPSTimeToFullChargeKey] as? Int, t > 0, charging { s.minutesToFull = t }
            s.condition = desc["BatteryHealthCondition"] as? String ?? desc[kIOPSBatteryHealthKey] as? String
            return s
        }
        return nil
    }

    // MARK: AppleSmartBattery (cycles, temperature, capacity)

    private static func mergeSmartBattery(into s: inout BatteryStats) {
        // Newer macOS releases moved several keys into nested "BatteryData" dictionaries,
        // some only on the AppleSmartBatteryPack child, so look in all of those places.
        var sources: [[String: Any]] = []
        for className in ["AppleSmartBattery", "AppleSmartBatteryPack"] {
            guard let props = properties(ofServiceClass: className) else { continue }
            sources.append(props)
            if let nested = props["BatteryData"] as? [String: Any] { sources.append(nested) }
        }
        func lookup(_ key: String) -> Int? {
            for dict in sources { if let v = dict[key] as? Int { return v } }
            return nil
        }

        s.cycleCount = lookup("CycleCount")
        s.designCycles = lookup("DesignCycleCount9C")
        s.designCapacity_mAh = lookup("DesignCapacity")
        s.currentCapacity_mAh = lookup("NominalChargeCapacity") ?? lookup("AppleRawMaxCapacity")
        if let t = lookup("Temperature") ?? lookup("VirtualTemperature"), t > 0 {
            s.temperatureC = Double(t) / 100   // reported in centi-degrees Celsius
        }
        if s.isPluggedIn {
            let details = sources.lazy.compactMap { $0["AdapterDetails"] as? [String: Any] }.first
            if let watts = details?["Watts"] as? Int, watts > 0 { s.adapterWatts = watts }
        }
    }

    private static func properties(ofServiceClass name: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    // MARK: system_profiler (the exact "Maximum Capacity" System Settings shows)

    struct ReportedHealth: Sendable { var maximumCapacity: Double?; var condition: String? }

    /// Slow (around 1 s), so call it rarely and off the main thread.
    static func fetchReportedHealth() async -> ReportedHealth? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPPowerDataType", "-json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = root["SPPowerDataType"] as? [[String: Any]],
                      let info = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first
                else { continuation.resume(returning: nil); return }

                var result = ReportedHealth()
                if let text = info["sppower_battery_health_maximum_capacity"] as? String,
                   let pct = Double(text.filter { $0.isNumber || $0 == "." }) {
                    result.maximumCapacity = pct / 100
                }
                result.condition = info["sppower_battery_health"] as? String
                continuation.resume(returning: result)
            }
        }
    }
}
