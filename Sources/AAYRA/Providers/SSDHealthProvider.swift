import CNVMe
import Foundation
import IOKit

/// Static facts about the internal SSD (they never change while the app runs).
struct SSDInfo: Equatable {
    var model: String?
    var serial: String?
    var firmware: String?
    var interconnect: String?  // e.g. "Apple Fabric"
    var mediumType: String?  // e.g. "Solid State"
    var bsdName: String?  // e.g. "disk0"
    var capacityBytes: Int64?
}

/// Health of the internal NVMe SSD, from its SMART / Health log.
struct SSDHealth: Equatable {
    var health: Double  // 0...1, i.e. 100 % minus the drive's own wear estimate
    var temperatureC: Double?
    var bytesWritten: UInt64
    var bytesRead: UInt64
    var powerOnHours: UInt64
    var powerCycles: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    var availableSpare: Int
    var availableSpareThreshold: Int
    var info: SSDInfo
    var hasCriticalWarning: Bool

    /// SMART indicators that warrant checking the drive; wear alone is not a failure warning.
    var hasSMARTWarning: Bool {
        hasCriticalWarning || mediaErrors > 0 || (availableSpareThreshold > 0 && availableSpare <= availableSpareThreshold)
    }

    /// Plain-language summary in the spirit of Disk Utility's "Verified / Failing".
    var condition: String {
        if hasSMARTWarning { return "Check Drive" }
        return health >= 0.5 ? "Good" : "Worn"
    }
}

enum SSDHealthProvider {
    static let info: SSDInfo = readInfo()

    /// Reads model, serial, firmware and size from the NVMe block device in the IORegistry.
    private static func readInfo() -> SSDInfo {
        var result = SSDInfo()
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"),
                &iterator) == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("NVMe SMART Capable") as? Bool) == true else { continue }

            let device = property("Device Characteristics") as? [String: Any] ?? [:]
            let proto = property("Protocol Characteristics") as? [String: Any] ?? [:]
            func text(_ value: Any?) -> String? {
                (value as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
            result.model = text(device["Product Name"]) ?? text(property("Model Number"))
            result.serial = text(device["Serial Number"]) ?? text(property("Serial Number"))
            result.firmware = text(device["Product Revision Level"]) ?? text(property("Firmware Revision"))
            result.mediumType = text(device["Medium Type"])
            result.interconnect = text(proto["Physical Interconnect"])

            // The first IOMedia below the device is the whole disk (e.g. disk0).
            let options = IOOptionBits(kIORegistryIterateRecursively)
            result.bsdName =
                IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, "BSD Name" as CFString,
                    kCFAllocatorDefault, options) as? String
            if let size = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "Size" as CFString,
                kCFAllocatorDefault, options) as? NSNumber
            {
                result.capacityBytes = size.int64Value
            }
            break
        }
        return result
    }

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
            availableSpareThreshold: Int(raw.availableSpareThreshold),
            info: info,
            hasCriticalWarning: raw.criticalWarning != 0
        )
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
