import Charts
import SwiftUI

/// The selected chart range, shared by the CPU and Network detail panels and remembered.
extension AppSettings.Key {
    static let historyRange = "historyRange"
}

/// 1m / 10m / 1h switch shown in a detail section's title row.
struct HistoryRangePicker: View {
    @Binding var range: HistoryRange
    #if DEBUG
        @Environment(\.isSnapshot) private var isSnapshot
    #else
        private let isSnapshot = false
    #endif

    var body: some View {
        if isSnapshot {  // AppKit controls can't be drawn offscreen; show the choice as text
            Text(range.title).font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Chart range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("How much history the chart shows")
        }
    }
}

/// One or two lines over the selected range, with "… ago" and "now" under the chart.
/// Buckets without readings (e.g. while the Mac slept) leave a gap instead of a misleading line.
struct HistoryChart: View {
    struct Series {
        let name: String
        let buckets: [Double?]
        let color: Color
    }

    let series: [Series]
    let range: HistoryRange
    /// Fixed top of the scale (1 for CPU), or nil to fit the data (network speeds).
    var maxValue: Double?
    var height: CGFloat = 40

    private struct Point: Identifiable {
        let id: String
        let series: String
        let segment: String  // a new segment starts after each gap, so lines don't bridge it
        let index: Int
        let value: Double
    }

    private var points: [Point] {
        // A stretch without readings only counts as a gap (e.g. the Mac slept) when it's longer than
        // a few refresh intervals; shorter holes come from readings landing a little late, or from a
        // 2 s or 5 s refresh rate that leaves most 1-second slots empty, and the line joins them up.
        let bucketSeconds = range.seconds / Double(range.buckets)
        let maxGap = Self.maxGapBuckets(bucketSeconds: bucketSeconds, refreshInterval: AppSettings.refreshInterval)
        return series.flatMap { s in
            zip(s.buckets.indices, Self.segments(s.buckets, maxGap: maxGap)).compactMap { index, segment -> Point? in
                guard let segment, let value = s.buckets[index] else { return nil }
                return Point(
                    id: "\(s.name)-\(index)", series: s.name, segment: "\(s.name)-\(segment)", index: index,
                    value: value)
            }
        }
    }

    /// Empty buckets in a row that still count as one continuous line.
    static func maxGapBuckets(bucketSeconds: TimeInterval, refreshInterval: TimeInterval) -> Int {
        max(2, Int((3 * refreshInterval / bucketSeconds).rounded(.up)))
    }

    /// Which line segment each bucket belongs to (nil for an empty bucket). A run of more than
    /// `maxGap` empty buckets starts a new segment, so the line breaks there instead of bridging it.
    static func segments(_ buckets: [Double?], maxGap: Int) -> [Int?] {
        var segment = 0, emptyRun = 0, seenValue = false
        return buckets.map { value in
            guard value != nil else {
                emptyRun += 1
                return nil
            }
            if seenValue && emptyRun > maxGap { segment += 1 }
            seenValue = true
            emptyRun = 0
            return segment
        }
    }

    var body: some View {
        let count = series.first?.buckets.count ?? 1
        let peak = points.map(\.value).max() ?? 0
        let top = maxValue ?? max(peak * 1.1, 1_024)
        VStack(spacing: 2) {
            Chart(points) { p in
                AreaMark(
                    x: .value("t", p.index), y: .value("v", p.value), series: .value("segment", p.segment),
                    stacking: .unstacked
                )
                .foregroundStyle(color(of: p.series).opacity(series.count > 1 ? 0.15 : 0.25))
                .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.index), y: .value("v", p.value), series: .value("segment", p.segment))
                    .foregroundStyle(color(of: p.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartXScale(domain: 0...max(count - 1, 1))
            .chartYScale(domain: 0...top)
            .frame(height: height)
            .animation(.smooth(duration: 0.3), value: range)
            .accessibilityHidden(true)

            HStack {
                Text("\(range.spanText) ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func color(of name: String) -> Color {
        series.first { $0.name == name }?.color ?? .accentColor
    }
}
