import Testing

@testable import AAYRA

/// The hour of history behind the detail charts' 1m / 10m / 1h ranges.
struct TimeSeriesTests {
    @Test func keepsOnlyTheWindow() {
        var series = TimeSeries(window: 60)
        for t in 0...120 { series.append(Double(t), at: Double(t)) }
        #expect(series.times.first == 60)  // the oldest kept reading is exactly one window back
        #expect(series.times.last == 120)
        #expect(series.values.count == 61)
    }

    @Test func peakAndAverageCoverOnlyTheRange() {
        var series = TimeSeries()
        series.append(100, at: 0)  // outside the last minute
        for t in 50...100 { series.append(10, at: Double(t)) }
        series.append(40, at: 101)
        #expect(series.peak(inLast: 60, now: 101) == 40)
        #expect(series.peak(inLast: 3_600, now: 101) == 100)
        let average = series.average(inLast: 60, now: 101) ?? 0
        #expect(abs(average - (10.0 * 51 + 40) / 52) < 1e-9)
        #expect(TimeSeries().average(inLast: 60, now: 0) == nil)
    }

    @Test func bucketsAverageTheirReadings() {
        var series = TimeSeries()
        // Two readings per 10-second bucket over the last minute: bucket i holds i and i + 2 → average i + 1.
        for bucket in 0..<6 {
            let start = Double(bucket * 10) + 1
            series.append(Double(bucket), at: start)
            series.append(Double(bucket + 2), at: start + 5)
        }
        // At t = 59 the six 10-second buckets are 0–10, 10–20 … 50–60.
        #expect(series.buckets(6, inLast: 60, now: 59) == [1, 2, 3, 4, 5, 6])
    }

    @Test func finishedBucketsDontChangeAsTimeMoves() {
        var series = TimeSeries()
        for t in 0..<600 { series.append(Double(t % 7), at: Double(t)) }  // uneven values, one per second
        let at599 = series.buckets(120, inLast: 600, now: 599)
        let at599_9 = series.buckets(120, inLast: 600, now: 599.9)
        #expect(at599 == at599_9)  // same buckets within the same 5 seconds
        series.append(3, at: 600)
        let at600 = series.buckets(120, inLast: 600, now: 600)
        // A new bucket starts: everything moves left by exactly one, unchanged.
        #expect(Array(at600.dropLast()) == Array(at599.dropFirst()))
        #expect(at600.last == 3)
    }

    @Test func emptyBucketsAreGaps() {
        var series = TimeSeries()
        series.append(5, at: 5)  // first bucket
        series.append(7, at: 55)  // last bucket; nothing in between (e.g. the Mac slept)
        let buckets = series.buckets(6, inLast: 60, now: 59)
        #expect(buckets.first == 5)
        #expect(buckets.last == 7)
        #expect(buckets.dropFirst().dropLast().allSatisfy { $0 == nil })
    }

    @Test func rangesUseSensiblePointCounts() {
        #expect(HistoryRange.minute.seconds / Double(HistoryRange.minute.buckets) == 1)  // 1 s per point
        #expect(HistoryRange.tenMinutes.seconds / Double(HistoryRange.tenMinutes.buckets) == 5)
        #expect(HistoryRange.hour.seconds / Double(HistoryRange.hour.buckets) == 30)
    }

    @Test func shortHolesJoinLongGapsBreak() {
        // Two empty slots (a late reading) stay one line; a long stretch (sleep) starts a new segment.
        let buckets: [Double?] = [1, 2, nil, nil, 3, 4] + Array(repeating: nil, count: 10) + [5, 6]
        let segments = HistoryChart.segments(buckets, maxGap: 2)
        #expect(segments[0] == 0 && segments[1] == 0 && segments[4] == 0 && segments[5] == 0)
        #expect(segments[2] == nil && segments[3] == nil)
        #expect(segments[16] == 1 && segments[17] == 1)
    }

    @Test func gapToleranceFollowsTheRefreshRate() {
        // 1-second points: a 1 s refresh tolerates 3 empty slots, a 5 s refresh tolerates 15.
        #expect(HistoryChart.maxGapBuckets(bucketSeconds: 1, refreshInterval: 1) == 3)
        #expect(HistoryChart.maxGapBuckets(bucketSeconds: 1, refreshInterval: 5) == 15)
        // 30-second points (1 h view): never less than 2 empty points.
        #expect(HistoryChart.maxGapBuckets(bucketSeconds: 30, refreshInterval: 1) == 2)
    }
}
