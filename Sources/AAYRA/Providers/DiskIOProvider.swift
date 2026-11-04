import Foundation
import IOKit

struct DiskIO: Equatable {
    var readBytesPerSec: Double = 0
    var writeBytesPerSec: Double = 0
    var totalRead: UInt64 = 0  // since boot, all drives
    var totalWritten: UInt64 = 0
}

/// Disk read/write speed from the byte counters every block storage driver keeps (the same numbers
/// Activity Monitor's Disk tab uses). Covers internal and external drives; no special permissions.
final class DiskIOProvider {
    private var last: (read: UInt64, write: UInt64, time: TimeInterval)?

    func sample() -> DiskIO {
        let counters = Self.readCounters()
        let now = ProcessInfo.processInfo.systemUptime
        var io = DiskIO(totalRead: counters.read, totalWritten: counters.write)
        if let last, now > last.time {
            let dt = now - last.time
            // Counters drop if a drive is ejected; show zero for that sample rather than a spike.
            io.readBytesPerSec = counters.read >= last.read ? Double(counters.read - last.read) / dt : 0
            io.writeBytesPerSec = counters.write >= last.write ? Double(counters.write - last.write) / dt : 0
        }
        last = (counters.read, counters.write, now)
        return io
    }

    private static func readCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard
                let stats = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString,
                    kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
            else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}
