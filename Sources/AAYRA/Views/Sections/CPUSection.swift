import SwiftUI

// CPU: the card in the panel and its detail panel.

struct CPUCard: View {
    let monitor: SystemMonitor

    var body: some View {
        let cpu = monitor.cpu
        Card(symbol: "cpu", tint: Palette.cpu) {
            MeterHeader(title: "CPU", value: Format.percent(cpu.total))
        } details: {
            Sparkline(values: monitor.cpuHistory, color: Palette.cpu, height: 22)
            StatRow(stats: [
                Stat(label: "User", value: Format.percent(cpu.user), dot: Palette.cpu),
                Stat(label: "System", value: Format.percent(cpu.system), dot: Palette.cpuSystem),
                Stat(label: "Load", value: String(format: "%.2f", cpu.loadAverage.0)),
            ])
        }
    }
}

struct CPUDetail: View {
    let monitor: SystemMonitor
    /// The one app in Top Processes that's expanded, if any.
    @State private var expandedProcess: String?
    @AppStorage(AppSettings.Key.historyRange) private var range = HistoryRange.minute

    var body: some View {
        let cpu = monitor.cpu
        DetailPanel(
            symbol: "cpu", tint: Palette.cpu, title: "CPU", subtitle: subtitle,
            actions: [.activityMonitor]
        ) {
            DetailSection("Usage") {
                HistoryRangePicker(range: $range)
            } content: {
                let series = monitor.cpuSeries, now = monitor.seriesTime
                HistoryChart(
                    series: [
                        .init(
                            name: "CPU", buckets: series.buckets(range.buckets, inLast: range.seconds, now: now),
                            color: Palette.cpu)
                    ],
                    range: range, maxValue: 1
                )
                .padding(.vertical, 2)
                DetailRow("Total", Format.percent(cpu.total))
                DetailRow(
                    "Average (\(range.spanText))",
                    series.average(inLast: range.seconds, now: now).map { Format.percent($0) } ?? "—")
                DetailRow(
                    "Peak (\(range.spanText))", series.peak(inLast: range.seconds, now: now).map { Format.percent($0) } ?? "—")
                DetailRow("User", Format.percent(cpu.user), dot: Palette.cpu)
                DetailRow("System", Format.percent(cpu.system), dot: Palette.cpuSystem)
                DetailRow("Idle", Format.percent(max(0, 1 - cpu.total)))
            }
            DetailSection("Cores") {
                if let groups {
                    CoreCluster(title: "Performance", loads: groups.p, tint: Palette.cpu)
                    CoreCluster(title: "Efficiency", loads: groups.e, tint: Palette.cpu)
                } else {
                    CoreCluster(title: "All cores", loads: cpu.perCoreUsage, tint: Palette.cpu)
                }
            }
        } trailing: {
            DetailSection("Chip") {
                DetailRow("Chip", MachineInfo.chip)
                if let model = ChipInfo.model { DetailRow("Model", model) }
                DetailRow("CPU cores", coresText)
                if let gpu = ChipInfo.gpuCores { DetailRow("GPU cores", "\(gpu)") }
                let pc = ChipInfo.performanceCache, ec = ChipInfo.efficiencyCache
                if let pl2 = pc.l2, let el2 = ec.l2 {
                    DetailRow("L2 cache", "\(pl2 / 1_048_576) MB (P) · \(el2 / 1_048_576) MB (E)")
                }
                if let i = pc.l1i, let d = pc.l1d { DetailRow("L1 per P core", "\(i / 1024) KB + \(d / 1024) KB") }
                if let i = ec.l1i, let d = ec.l1d { DetailRow("L1 per E core", "\(i / 1024) KB + \(d / 1024) KB") }
            }
            DetailSection("System") {
                let l = cpu.loadAverage
                DetailRow("Load average", String(format: "%.2f · %.2f · %.2f", l.0, l.1, l.2))
                DetailRow("Thermal state", monitor.thermalState.label, dot: monitor.thermalState.color)
                if monitor.processCount > 0 { DetailRow("Processes", monitor.processCount.formatted()) }
                if let boot = monitor.bootDate {
                    DetailRow("Uptime", Format.uptime(since: boot))
                    DetailRow("Booted", boot.formatted(date: .abbreviated, time: .shortened))
                }
                if let kernel = ChipInfo.kernel {
                    DetailRow("Kernel", "Darwin \(kernel)" + (ChipInfo.build.map { " (\($0))" } ?? ""))
                }
            }
            topProcesses
        }
    }

    private var topProcesses: some View {
        DetailSection("Top Processes") {
            if monitor.topCPUProcesses.isEmpty {
                EmptyRow(text: "Measuring…")
            } else {
                ForEach(monitor.topCPUProcesses) { process in
                    ProcessRow(
                        name: process.name, value: String(format: "%.1f%%", process.percent),
                        fraction: process.percent / 100, tint: Palette.cpu, iconPath: process.id,
                        count: process.count,
                        members: process.members.map {
                            .init(id: $0.id, name: $0.name, value: String(format: "%.1f%%", $0.value))
                        },
                        isExpanded: expandedProcess == process.id,
                        onToggle: { expandedProcess = expandedProcess == process.id ? nil : process.id })
                }
            }
        }
    }

    private var subtitle: String {
        "\(MachineInfo.chip) · \(monitor.cpu.perCore.count) cores"
    }

    private var coresText: String {
        let p = monitor.performanceCores, e = monitor.efficiencyCores
        return p > 0 && e > 0 ? "\(p + e) (\(p)P + \(e)E)" : "\(monitor.cpu.perCore.count)"
    }

    /// Per-core loads split into performance and efficiency clusters, when the layout is known.
    private var groups: (p: [CPUCoreUsage], e: [CPUCoreUsage])? {
        let clusters = ChipInfo.coreClusters, loads = monitor.cpu.perCoreUsage
        guard clusters.count == loads.count, !clusters.isEmpty else { return nil }
        let pairs = zip(clusters, loads)
        return (pairs.filter { $0.0 == "P" }.map(\.1), pairs.filter { $0.0 == "E" }.map(\.1))
    }

}

/// One CPU cluster with a live, stacked user/system meter per core.
private struct CoreCluster: View {
    let title: String
    let loads: [CPUCoreUsage]
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Text("\(loads.count) cores").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(average)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.body)
            HStack(spacing: 12) {
                Label {
                    Text("User")
                } icon: {
                    Circle().fill(tint).frame(width: 6, height: 6)
                }
                Label {
                    Text("System")
                } icon: {
                    Circle().fill(Palette.cpuSystem).frame(width: 6, height: 6)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(loads.enumerated()), id: \.offset) { index, load in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(.quaternary)
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(tint)
                                    .frame(height: 58 * load.user)
                                Rectangle()
                                    .fill(Palette.cpuSystem)
                                    .frame(height: 58 * load.system)
                            }
                        }
                        .frame(height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: load)
                        Text("\(Int((load.total * 100).rounded()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 40)
                    .accessibilityElement()
                    .accessibilityLabel("Core \(index + 1)")
                    .accessibilityValue(
                        "\(Format.percent(load.total)) total, \(Format.percent(load.user)) user, \(Format.percent(load.system)) system"
                    )
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var average: String {
        loads.isEmpty ? "—" : Format.percent(loads.reduce(0) { $0 + $1.total } / Double(loads.count))
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair (warm)"
        case .serious: "Serious (throttling)"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }
}
