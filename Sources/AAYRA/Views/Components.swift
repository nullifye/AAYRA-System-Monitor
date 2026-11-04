import Charts
import SwiftUI

/// One distinct colour per section, used for its icon badge, bars and charts.
enum Palette {
    static let cpu = Color.blue
    static let cpuSystem = Color.red
    static let storage = Color.purple
    static let memory = Color.pink
    static let battery = Color.green
    static let network = Color.teal
    static let download = Color.blue
    static let upload = Color.orange
}

/// Shared sizes for the compact layout, so every card lines up.
enum Metrics {
    static let panelWidth: CGFloat = 312
    static let badge: CGFloat = 18
    static let titleWidth: CGFloat = 54
    static let valueWidth: CGFloat = 84
    static let headerHeight: CGFloat = 18
}

/// System Settings–style icon: white glyph on a filled, rounded colour tile.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = Metrics.badge

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .shadow(color: color.opacity(0.3), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Compact card: one header line (badge + caller-supplied content), then optional detail lines.
struct Card<Header: View, Details: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var header: () -> Header
    @ViewBuilder var details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                IconBadge(symbol: symbol, color: tint)
                header()
            }
            .frame(height: Metrics.headerHeight)
            details()
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The standard header: fixed-width title, a flexible middle (bar or chart), fixed-width value.
struct MeterHeader<Middle: View>: View {
    let title: String
    let value: String
    @ViewBuilder var middle: () -> Middle

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .frame(width: Metrics.titleWidth, alignment: .leading)
        middle()
            .frame(maxWidth: .infinity)
        Text(value)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
            .frame(width: Metrics.valueWidth, alignment: .trailing)
    }
}

/// "Label value" pair for detail lines: secondary label, primary value.
struct Stat: View {
    let label: String
    let value: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if !label.isEmpty { Text(label) }
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .fixedSize()
    }
}

/// Thin capsule meter that moves from the section colour to orange to red as it fills.
struct UsageBar: View {
    let fraction: Double
    var warning = 0.75
    var critical = 0.9
    var color: Color?
    var tint: Color = .accentColor
    var height: CGFloat = 5

    private var fill: Color {
        if let color { return color }
        return fraction >= critical ? .red : fraction >= warning ? .orange : tint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fill.gradient)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.4), value: fraction)
        .accessibilityElement()
        .accessibilityValue(Format.percent(fraction))
    }
}

/// Live area chart of recent values.
struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = 1
    var color: Color = .accentColor
    var height: CGFloat = Metrics.headerHeight

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.4), color.opacity(0.03)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.1))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...(max(values.count - 1, 1)))
        .chartYScale(domain: 0...(maxValue ?? max(values.max() ?? 1, 1)))
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Download and upload history drawn together on a shared scale.
struct DualSparkline: View {
    let download: [Double]
    let upload: [Double]
    var height: CGFloat = Metrics.headerHeight

    private struct Point: Identifiable {
        let id: Int; let t: Int; let value: Double; let series: String
    }

    private var points: [Point] {
        download.enumerated().map { Point(id: $0.offset, t: $0.offset, value: $0.element, series: "Download") }
            + upload.enumerated().map { Point(id: 10_000 + $0.offset, t: $0.offset, value: $0.element, series: "Upload") }
    }

    var body: some View {
        let peak = max(download.max() ?? 0, upload.max() ?? 0, 1024)
        Chart(points) { p in
            AreaMark(x: .value("t", p.t), y: .value("v", p.value), stacking: .unstacked)
                .foregroundStyle(by: .value("Series", p.series))
                .opacity(0.18)
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.t), y: .value("v", p.value))
                .foregroundStyle(by: .value("Series", p.series))
                .lineStyle(StrokeStyle(lineWidth: 1.1))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(["Download": Palette.download, "Upload": Palette.upload])
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...(max(download.count - 1, 1)))
        .chartYScale(domain: 0...peak * 1.1)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Row of tiny vertical bars, one per CPU core.
struct CoreBars: View {
    let loads: [Double]
    var tint: Color = Palette.cpu
    var height: CGFloat = 12

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill((load > 0.9 ? Color.red : load > 0.7 ? Color.orange : tint).gradient)
                        .frame(height: max(1.5, height * min(load, 1)))
                }
                .frame(width: 5, height: height)
            }
        }
        .animation(.smooth(duration: 0.4), value: loads)
        .accessibilityHidden(true)
    }
}
