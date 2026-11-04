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
    var adapterName: String?
    var fullChargeCapacity_mAh: Int?
    /// Battery power flow in watts: positive while charging, negative while discharging.
    var powerWatts: Double?
    var serial: String?
    /// Maker of the lithium cells inside the pack (from the gauge's manufacturer data), e.g. "ATL".
    var manufacturer: String?
    /// Company that assembled the pack (from the serial-number prefix), e.g. "Sunwoda".
    var packManufacturer: String?
    /// Pack manufacture date; `manufactureDateIsEstimate` when derived from operating time.
    var manufactureDate: Date?
    var manufactureDateIsEstimate = false

    // Live electrical readings
    var voltage_mV: Int?
    var current_mA: Int?                   // negative while discharging
    var cellVoltages_mV: [Int] = []
    var remaining_mAh: Int?
    var rawMax_mAh: Int?
    var systemLoadWatts: Double?           // what the whole Mac is drawing
    var adapterInputWatts: Double?         // power coming in from the charger
    var dailyMinSoc: Int?                  // today's lowest / highest charge, percent
    var dailyMaxSoc: Int?

    // Lifetime record kept by the battery's fuel gauge
    var lifetimeMinTempC: Int?
    var lifetimeMaxTempC: Int?
    var lifetimeAvgTempC: Double?
    var maxChargeCurrent_mA: Int?
    var maxDischargeCurrent_mA: Int?
    var minPackVoltage_mV: Int?
    var maxPackVoltage_mV: Int?
    var operatingHours: Int?
    var permanentFailure: Int?
    var cellDisconnects: Int?
    var thermallyLimitedCharging: Int?
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
            if let nested = props["BatteryData"] as? [String: Any] {
                sources.append(nested)
                if let lifetime = nested["LifetimeData"] as? [String: Any] { sources.append(lifetime) }
            }
            for extra in ["PowerTelemetryData", "ChargerData"] {
                if let dict = props[extra] as? [String: Any] { sources.append(dict) }
            }
        }
        func lookup(_ key: String) -> Int? {
            // NSNumber.int64Value also handles signed values that ioreg shows as huge unsigned numbers.
            for dict in sources { if let v = dict[key] as? NSNumber { return Int(v.int64Value) } }
            return nil
        }
        func lookupAny(_ key: String) -> Any? {
            for dict in sources { if let v = dict[key] { return v } }
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
            s.adapterName = (details?["Name"] as? String) ?? (details?["Description"] as? String)
        }

        s.fullChargeCapacity_mAh = lookup("FullChargeCapacity") ?? lookup("AppleRawMaxCapacity")
        if let mV = lookup("Voltage"), let mA = lookup("InstantAmperage") ?? lookup("Amperage") {
            s.powerWatts = Double(mV) * Double(mA) / 1_000_000
        }
        s.serial = (lookupAny("Serial") as? String).flatMap { $0.isEmpty ? nil : $0 }
        s.packManufacturer = s.serial.flatMap(packAssembler)
        s.manufacturer = (lookupAny("ManufacturerData") as? Data ?? lookupAny("MfgData") as? Data)
            .flatMap(cellManufacturer)

        s.voltage_mV = lookup("Voltage")
        s.current_mA = lookup("InstantAmperage") ?? lookup("Amperage")
        s.cellVoltages_mV = cellVoltages()
        s.remaining_mAh = lookup("AppleRawCurrentCapacity")
        s.rawMax_mAh = lookup("AppleRawMaxCapacity")
        if let mW = lookup("SystemLoad"), mW > 0 { s.systemLoadWatts = Double(mW) / 1000 }
        if let mW = lookup("SystemPowerIn"), mW > 0 { s.adapterInputWatts = Double(mW) / 1000 }
        s.dailyMinSoc = lookup("DailyMinSoc")
        s.dailyMaxSoc = lookup("DailyMaxSoc")
        s.lifetimeMinTempC = lookup("MinimumTemperature")
        s.lifetimeMaxTempC = lookup("MaximumTemperature")
        s.lifetimeAvgTempC = lookup("AverageTemperature").map { Double($0) / 10 }   // tenths of °C
        s.maxChargeCurrent_mA = lookup("MaximumChargeCurrent")
        s.maxDischargeCurrent_mA = lookup("MaximumDischargeCurrent")
        s.minPackVoltage_mV = lookup("MinimumPackVoltage")
        s.maxPackVoltage_mV = lookup("MaximumPackVoltage")
        s.operatingHours = lookup("TotalOperatingTime")
        s.permanentFailure = lookup("PermanentFailureStatus")
        s.cellDisconnects = lookup("BatteryCellDisconnectCount")
        s.thermallyLimitedCharging = lookup("TimeChargingThermallyLimited")

        if let raw = lookupAny("ManufactureDate") as? NSNumber, let date = decodeManufactureDate(raw.uint64Value) {
            s.manufactureDate = date
        } else if let hours = lookup("TotalOperatingTime"), hours > 0 {
            // The fuel gauge counts hours since the pack was first powered, so this approximates its age.
            s.manufactureDate = Date().addingTimeInterval(-Double(hours) * 3600)
            s.manufactureDateIsEstimate = true
        }
    }

    /// Apple Silicon packs store the date as six ASCII digits, little-endian, laid out DDMMYY
    /// (e.g. 0x333230313133 → "311023" → 31 Oct 2023). Not every pack follows it, so validate.
    private static func decodeManufactureDate(_ value: UInt64) -> Date? {
        let bytes = (0..<6).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
        guard bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        let digits = bytes.map { Int($0) - 0x30 }
        let day = digits[0] * 10 + digits[1], month = digits[2] * 10 + digits[3], year = 2000 + digits[4] * 10 + digits[5]
        var parts = DateComponents(year: year, month: month, day: day)
        parts.calendar = Calendar(identifier: .gregorian)
        guard (1...12).contains(month), (1...31).contains(day), parts.isValidDate,
              let date = parts.date, date <= Date(), year >= 2010 else { return nil }
        return date
    }

    /// Apple battery serials start with a three-character code for the pack assembler
    /// (the same source coconutBattery uses). Only well-documented codes are listed.
    private static func packAssembler(fromSerial serial: String) -> String? {
        let codes = ["F8Y": "Sunwoda", "F5D": "Sunwoda", "D86": "Desay", "D3H": "Desay",
                     "C01": "Simplo", "C32": "Simplo"]
        return codes[String(serial.prefix(3)).uppercased()]
    }

    /// The manufacturer data block holds length-prefixed ASCII fields; the last alphabetic one is the cell maker code.
    private static func cellManufacturer(from data: Data) -> String? {
        let bytes = [UInt8](data)
        var fields: [String] = []
        var i = 0
        while i < bytes.count {
            let length = Int(bytes[i])
            if (2...8).contains(length), i + length < bytes.count {
                let chunk = bytes[(i + 1)...(i + length)]
                if chunk.allSatisfy({ (0x20...0x7E).contains($0) }) {
                    fields.append(String(decoding: chunk, as: UTF8.self))
                    i += length + 1
                    continue
                }
            }
            i += 1
        }
        guard let code = fields.last(where: { $0.allSatisfy(\.isLetter) }) else { return nil }
        let names = ["ATL": "ATL (Amperex)", "SMP": "Simplo", "SWD": "Sunwoda", "DSY": "Desay",
                     "LGC": "LG Chem", "SDI": "Samsung SDI", "SNY": "Sony", "BYD": "BYD", "COS": "Coslight"]
        return names[code] ?? code
    }

    /// Each AppleSmartBatteryBank (one per cell group) reports its own cell voltage.
    private static func cellVoltages() -> [Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryBank"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var voltages: [Int] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let mV = (data["CellVoltage"] as? NSNumber)?.intValue, mV > 0 {
                voltages.append(mV)
            }
        }
        return voltages
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
