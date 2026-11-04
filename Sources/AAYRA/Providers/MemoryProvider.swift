import Darwin
import Foundation
import IOKit

/// Static facts about the installed RAM, from the device tree (e.g. "LPDDR5", "Micron").
enum MemoryHardware {
    static let (type, vendor): (String?, String?) = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
        guard entry != 0 else { return (nil, nil) }
        defer { IOObjectRelease(entry) }
        func text(_ key: String) -> String? {
            guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { return nil }
            let value = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            return value.isEmpty ? nil : value
        }
        return (text("dram-type"), text("dram-vendor"))
    }()
}

struct MemoryStats: Equatable {
    enum Pressure { case normal, warning, critical }

    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var free: UInt64 = 0
    var pressure: Pressure = .normal
    /// Kernel's "memory free percentage" (what `memory_pressure` reports).
    var freePercent: Int?
    // Counters since boot.
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var swapIns: UInt64 = 0
    var swapOuts: UInt64 = 0
    var compressions: UInt64 = 0
    var decompressions: UInt64 = 0

    /// Matches Activity Monitor's "Memory Used" (app + wired + compressed).
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemoryProvider {
    static func sample() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        var result = MemoryStats()
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        result.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        result.wired = UInt64(stats.wire_count) * page
        result.compressed = UInt64(stats.compressor_page_count) * page
        result.cached = (UInt64(stats.external_page_count) + purgeable) * page
        result.free = UInt64(stats.free_count) * page
        result.pageIns = UInt64(stats.pageins)
        result.pageOuts = UInt64(stats.pageouts)
        result.swapIns = UInt64(stats.swapins)
        result.swapOuts = UInt64(stats.swapouts)
        result.compressions = UInt64(stats.compressions)
        result.decompressions = UInt64(stats.decompressions)
        result.freePercent = Sysctl.int("kern.memorystatus_level")

        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage()) {
            result.swapUsed = swap.xsu_used
            result.swapTotal = swap.xsu_total
        }
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: result.pressure = .critical
        case 2: result.pressure = .warning
        default: result.pressure = .normal
        }
        return result
    }
}
