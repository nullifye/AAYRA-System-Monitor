import Foundation

/// Readings with their time, kept for a fixed window (an hour by default), oldest first.
/// Times are system uptime in seconds, so they keep counting across refresh-interval changes.
struct TimeSeries: Equatable {
    let window: TimeInterval
    private(set) var times: [TimeInterval] = []
    private(set) var values: [Double] = []

    init(window: TimeInterval = 3_600) {
        self.window = window
    }

    var isEmpty: Bool { times.isEmpty }

    mutating func append(_ value: Double, at time: TimeInterval) {
        times.append(time)
        values.append(value)
        // Drop readings older than the window (normally just one per tick).
        let cutoff = time - window
        if let firstKept = times.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
            times.removeFirst(firstKept)
            values.removeFirst(firstKept)
        }
    }

    /// Readings from the last `seconds` up to `now`.
    func values(inLast seconds: TimeInterval, now: TimeInterval) -> ArraySlice<Double> {
        let start = times.firstIndex { $0 >= now - seconds } ?? times.count
        return values[start...]
    }

    func peak(inLast seconds: TimeInterval, now: TimeInterval) -> Double? {
        values(inLast: seconds, now: now).max()
    }

    func average(inLast seconds: TimeInterval, now: TimeInterval) -> Double? {
        let slice = values(inLast: seconds, now: now)
        return slice.isEmpty ? nil : slice.reduce(0, +) / Double(slice.count)
    }

    /// The last `seconds` split into `count` equal buckets, each the average of its readings,
    /// oldest first. A bucket with no readings (e.g. while the Mac slept) is nil.
    ///
    /// Bucket edges are fixed points in time (multiples of the bucket width), not measured back
    /// from `now`. So a finished bucket never changes and the chart scrolls one bucket at a time;
    /// only the newest bucket, which holds "now", keeps filling in. (Edges counted back from `now`
    /// shift every second, moving readings between buckets and making the whole line wobble.)
    func buckets(_ count: Int, inLast seconds: TimeInterval, now: TimeInterval) -> [Double?] {
        guard count > 0, seconds > 0 else { return [] }
        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)
        let width = seconds / Double(count)
        let newest = (now / width).rounded(.down)  // number of the bucket that holds `now`
        let oldest = newest - Double(count - 1)
        for (time, value) in zip(times, values) where time <= now {
            let index = Int((time / width).rounded(.down) - oldest)
            guard index >= 0 else { continue }  // older than the chart
            sums[min(index, count - 1)] += value
            counts[min(index, count - 1)] += 1
        }
        return (0..<count).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil }
    }
}

/// How much history the detail charts show (Settings remember the choice).
enum HistoryRange: String, CaseIterable, Identifiable {
    case minute = "1m"
    case tenMinutes = "10m"
    case hour = "1h"

    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .minute: 60
        case .tenMinutes: 600
        case .hour: 3_600
        }
    }
    /// Points on the chart: one per second for a minute, then 5-second and 30-second averages.
    var buckets: Int {
        switch self {
        case .minute: 60
        case .tenMinutes, .hour: 120
        }
    }
    var title: String {
        switch self {
        case .minute: "1m"
        case .tenMinutes: "10m"
        case .hour: "1h"
        }
    }
    /// For row labels, e.g. "Peak (10 min)".
    var spanText: String {
        switch self {
        case .minute: "1 min"
        case .tenMinutes: "10 min"
        case .hour: "1 hour"
        }
    }
}
