import Darwin
import Foundation

struct MemoryStats: Equatable {
    enum Pressure { case normal, warning, critical }

    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Pressure = .normal

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

        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage()) {
            result.swapUsed = swap.xsu_used
        }
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: result.pressure = .critical
        case 2: result.pressure = .warning
        default: result.pressure = .normal
        }
        return result
    }
}
