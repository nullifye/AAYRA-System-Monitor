import Foundation
import IOKit

/// Static facts about the processor, read once.
enum ChipInfo {
    /// Cluster type ("P" or "E") for each logical CPU, indexed like `CPUStats.perCore`.
    static let coreClusters: [String] = {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var byID: [Int: String] = [:]
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            func value(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(cpu, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let id = (value("logical-cpu-id") as? NSNumber)?.intValue,
                let data = value("cluster-type") as? Data
            else { continue }
            byID[id] = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard !byID.isEmpty else { return [] }
        return (0...(byID.keys.max() ?? 0)).map { byID[$0] ?? "?" }
    }()

    static let gpuCores: Int? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return
            (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }()

    static let model = Sysctl.string("hw.model")
    static let kernel = Sysctl.string("kern.osrelease")
    static let build = Sysctl.string("kern.osversion")

    struct Cache { let l1i: Int?; let l1d: Int?; let l2: Int? }
    static let performanceCache = Cache(
        l1i: Sysctl.int("hw.perflevel0.l1icachesize"),
        l1d: Sysctl.int("hw.perflevel0.l1dcachesize"),
        l2: Sysctl.int("hw.perflevel0.l2cachesize"))
    static let efficiencyCache = Cache(
        l1i: Sysctl.int("hw.perflevel1.l1icachesize"),
        l1d: Sysctl.int("hw.perflevel1.l1dcachesize"),
        l2: Sysctl.int("hw.perflevel1.l2cachesize"))
}
