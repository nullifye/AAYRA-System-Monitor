import Foundation
import IOKit

struct GPUStats: Equatable {
    var device: Double = 0  // overall busy fraction, 0…1 (Activity Monitor's GPU figure)
    var renderer: Double = 0  // pixel / fragment work
    var tiler: Double = 0  // geometry / vertex work
    var memoryInUse: UInt64 = 0  // unified memory the GPU is using right now
    var memoryAllocated: UInt64 = 0  // unified memory set aside for the GPU
    var recoveries = 0  // GPU restarts after a hang since boot
    var model: String?  // e.g. "Apple M4"
}

/// GPU load from the graphics driver's performance statistics (the IOAccelerator service).
/// Public IOKit, no special permissions; Apple Silicon and recent AMD/Intel drivers report these keys.
enum GPUProvider {
    /// The GPU's driver service, found once and kept (looking it up every second costs more than reading it).
    private static var service: io_service_t = 0
    private static var model: String?

    static func sample() -> GPUStats? {
        var gpu = service != 0 ? read(service) : nil
        if gpu == nil {  // first call, or the driver was replaced: look it up again
            findService()
            gpu = service != 0 ? read(service) : nil
        }
        gpu?.model = model
        return gpu
    }

    private static func findService() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            if service == 0, read(candidate) != nil {
                service = candidate  // keep this reference
                model =
                    IORegistryEntryCreateCFProperty(candidate, "model" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            } else {
                IOObjectRelease(candidate)
            }
        }
    }

    /// Reads just the performance statistics, not the driver's whole property table.
    private static func read(_ service: io_service_t) -> GPUStats? {
        guard
            let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString,
                kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
            let device = number(stats["Device Utilization %"])
        else { return nil }
        var gpu = GPUStats()
        gpu.device = fraction(device)
        gpu.renderer = fraction(number(stats["Renderer Utilization %"]) ?? device)
        gpu.tiler = fraction(number(stats["Tiler Utilization %"]) ?? 0)
        gpu.memoryInUse = UInt64(max(0, number(stats["In use system memory"]) ?? 0))
        gpu.memoryAllocated = UInt64(max(0, number(stats["Alloc system memory"]) ?? 0))
        gpu.recoveries = Int(number(stats["recoveryCount"]) ?? 0)
        return gpu
    }

    private static func number(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private static func fraction(_ percent: Int64) -> Double { min(max(Double(percent) / 100, 0), 1) }
}
