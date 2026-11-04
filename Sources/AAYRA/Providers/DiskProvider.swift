import Foundation

struct DiskStats: Equatable {
    var volumeName: String = "Macintosh HD"
    var total: Int64 = 0
    var available: Int64 = 0      // free + purgeable (what Finder reports as available)
    var free: Int64 = 0           // truly empty space
    var purgeable: Int64 { max(0, available - free) }

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum DiskProvider {
    static func sample() -> DiskStats? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        // "Important usage" includes purgeable space and matches the figure Finder shows.
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? free
        return DiskStats(volumeName: values.volumeName ?? "Macintosh HD",
                         total: Int64(total), available: max(available, free), free: free)
    }
}
