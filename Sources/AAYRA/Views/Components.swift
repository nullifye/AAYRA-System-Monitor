import Charts
import SwiftUI

/// One distinct colour per section, used for its icon badge, bars and charts.
enum Palette {
    static let cpu = Color.blue
    static let cpuSystem = Color.red
    static let cpuEfficiency = Color.cyan
    static let storage = Color.purple
    static let memory = Color.pink
    static let battery = Color.green
    static let network = Color.teal
    static let download = Color.blue
    static let upload = Color.orange
    static let diskRead = Color.blue
    static let diskWrite = Color.orange

    // Stacked-bar segments
    static let storagePurgeable = Color.purple.opacity(0.4)
    static let memoryWired = Color.orange
    static let memoryCompressed = Color.yellow
    static let memoryCached = Color.gray.opacity(0.55)
    static let batteryWorn = Color.gray.opacity(0.5)
}

/// Shared sizes for the compact layout, so every card lines up.
enum Metrics {
    static let panelWidth: CGFloat = 370
    static let badge: CGFloat = 30
    static let headerHeight: CGFloat = 18
    static let cardRadius: CGFloat = 18
    static let floatMargin: CGFloat = 12
    static let detailWidth: CGFloat = 640   // two columns of sections
}

/// Control Center–style icon: white glyph on a filled colour circle.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = Metrics.badge

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .shadow(color: color.opacity(0.3), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Dashboard card: a large icon on the left, a title with a big headline number, then detail lines.
struct Card<Header: View, Details: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var header: () -> Header
    @ViewBuilder var details: () -> Details

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(symbol: symbol, color: tint)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { header() }
                details()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(floating: true)
    }
}

extension EnvironmentValues {
    /// On only for offscreen debug renders (README screenshots): they can't draw glass, materials
    /// or AppKit controls, and personal identifiers are swapped for placeholders.
    @Entry var isSnapshot = false
}

/// Two card surfaces:
/// - floating: a Notification Center–style tile that hovers over the desktop on its own. Liquid Glass
///   on macOS 26+ (glass over content, as Apple intends), a blurred material with a soft shadow before.
/// - platter: a solid, lighter rounded surface for groups inside a popover, which is already glass,
///   so glass is never stacked on glass and text stays easy to read.
private struct CardBackground: ViewModifier {
    var radius: CGFloat
    var floating: Bool
    @Environment(\.colorScheme) private var scheme
    #if DEBUG
    @Environment(\.isSnapshot) private var isSnapshot
    #else
    private let isSnapshot = false   // screenshots are a debug-only feature
    #endif

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if floating {
            if #available(macOS 26, *), !isSnapshot {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background {
                    Group {
                        if !isSnapshot {
                            shape.fill(.regularMaterial)
                        } else {
                            shape.fill(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
            }
        } else {
            content.background {
                shape
                    .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.6))
                    .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), lineWidth: 0.5))
            }
        }
    }
}

extension View {
    func cardBackground(radius: CGFloat = Metrics.cardRadius, floating: Bool = false) -> some View {
        modifier(CardBackground(radius: radius, floating: floating))
    }
}

/// Card title on the left, the headline number on the right.
struct MeterHeader: View {
    let title: String
    let value: String
    var suffix: String?

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .lineLimit(1)
        Spacer(minLength: 8)
        BigValue(value, suffix: suffix)
    }
}

/// A large rounded number with its unit in smaller secondary text: "24 %", "40.8 GB free".
struct BigValue: View {
    let number: String
    let unit: String?
    var size: CGFloat = 22

    /// Splits "40.8 GB" into "40.8" + "GB" and "24%" into "24" + "%"; `suffix` is appended to the unit.
    init(_ text: String, suffix: String? = nil, size: CGFloat = 22) {
        var number = text, unit: String?
        if text.hasSuffix("%") {
            number = String(text.dropLast()); unit = "%"
        } else if let space = text.lastIndex(of: " ") {
            number = String(text[..<space]); unit = String(text[text.index(after: space)...])
        }
        self.number = number
        self.unit = [unit, suffix].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        self.size = size
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(number)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Stats in equal, fixed columns, so nothing shifts sideways when a value changes width.
struct StatRow: View {
    let stats: [Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(stats.indices, id: \.self) { i in
                stats[i].frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

/// Capsule bar split into coloured parts (fractions of the whole, left to right).
/// Whatever is left over shows as the empty track.
struct StackedBar: View {
    struct Segment {
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6
    var gap: CGFloat = 1

    @Environment(\.displayScale) private var displayScale

    /// Rounds to the nearest device pixel so every gap renders exactly the same width.
    private func snap(_ x: CGFloat) -> CGFloat { (x * displayScale).rounded() / displayScale }

    /// Left/right edges of each segment, pixel-aligned, with one uniform gap after each part.
    private func frames(width: CGFloat) -> [(x: CGFloat, width: CGFloat)] {
        var result: [(CGFloat, CGFloat)] = []
        var cumulative = 0.0
        for segment in segments {
            let value = max(0, min(segment.value, 1 - cumulative))
            let left = snap(CGFloat(cumulative) * width)
            cumulative += value
            let right = snap(CGFloat(cumulative) * width)
            let w = right - left - gap
            result.append((left, value > 0 && w >= 1 / displayScale ? w : 0))
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let rects = frames(width: geo.size.width)
            ZStack(alignment: .leading) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].color)
                        .frame(width: rects[i].width, height: height)
                        .offset(x: rects[i].x)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .leading)
        }
        .frame(height: height)
        .background(Capsule().fill(.quaternary))
        .clipShape(Capsule())
        .animation(.smooth(duration: 0.4), value: segments.map(\.value))
        .accessibilityElement()
        .accessibilityValue(Format.percent(segments.reduce(0) { $0 + $1.value }))
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

/// Makes a card clickable: it highlights on hover and presents its detail panel
/// in a popover beside the main panel.
/// Clicking anywhere outside the popover closes it.
struct DetailPopover<Detail: View>: ViewModifier {
    let kind: DetailKind
    @Binding var selection: DetailKind?
    let edge: Edge
    let tint: Color
    @ViewBuilder var detail: () -> Detail

    @State private var isHovering = false
    @State private var closedAt = Date.distantPast

    private var isOpen: Bool { selection == kind }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        content
            .overlay(shape.fill(Color.primary.opacity(isHovering || isOpen ? 0.05 : 0)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(tint.opacity(isOpen ? 0.6 : 0), lineWidth: 1))
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .onTapGesture {
                // A click on the open card first dismisses the popover; don't reopen it straight away.
                if !isOpen, Date().timeIntervalSince(closedAt) < 0.3 { return }
                selection = isOpen ? nil : kind
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isOpen)
            .popover(isPresented: Binding(
                get: { selection == kind },
                set: { shown in
                    if !shown, selection == kind {
                        selection = nil
                        closedAt = Date()
                    }
                }
            ), arrowEdge: edge) {
                detail()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows details")
    }
}

extension View {
    func detailPopover<Detail: View>(_ kind: DetailKind, selection: Binding<DetailKind?>, edge: Edge, tint: Color,
                                     @ViewBuilder detail: @escaping () -> Detail) -> some View {
        modifier(DetailPopover(kind: kind, selection: selection, edge: edge, tint: tint, detail: detail))
    }
}
