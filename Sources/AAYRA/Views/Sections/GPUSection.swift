import SwiftUI

// GPU: the card in the panel and its detail panel.

struct GPUCard: View {
    let monitor: SystemMonitor

    var body: some View {
        let gpu = monitor.gpu ?? GPUStats()
        Card(symbol: Palette.gpuSymbol, tint: Palette.gpu) {
            MeterHeader(title: "GPU", value: Format.percent(gpu.device))
        } details: {
            Sparkline(values: monitor.gpuHistory, color: Palette.gpu, height: 22)
            StatRow(stats: [
                Stat(label: "Render", value: Format.percent(gpu.renderer), dot: Palette.gpu),
                Stat(label: "Tiler", value: Format.percent(gpu.tiler)),
                Stat(label: "Mem.", value: Format.memoryShort(gpu.memoryInUse)),
            ])
        }
    }
}

struct GPUDetail: View {
    let monitor: SystemMonitor
    @AppStorage(AppSettings.Key.historyRange) private var range = HistoryRange.minute

    var body: some View {
        let gpu = monitor.gpu ?? GPUStats()
        DetailPanel(
            symbol: Palette.gpuSymbol, tint: Palette.gpu, title: "GPU", subtitle: subtitle(gpu),
            actions: [.activityMonitor]
        ) {
            DetailSection("Usage") {
                HistoryRangePicker(range: $range)
            } content: {
                let series = monitor.gpuSeries, now = monitor.seriesTime
                HistoryChart(
                    series: [
                        .init(
                            name: "GPU", buckets: series.buckets(range.buckets, inLast: range.seconds, now: now),
                            color: Palette.gpu)
                    ],
                    range: range, maxValue: 1
                )
                .padding(.vertical, 2)
                DetailRow("Overall", Format.percent(gpu.device), dot: Palette.gpu)
                DetailRow(
                    "Average (\(range.spanText))",
                    series.average(inLast: range.seconds, now: now).map { Format.percent($0) } ?? "—")
                DetailRow(
                    "Peak (\(range.spanText))", series.peak(inLast: range.seconds, now: now).map { Format.percent($0) } ?? "—")
                DetailRow("Renderer (pixels)", Format.percent(gpu.renderer))
                DetailRow("Tiler (geometry)", Format.percent(gpu.tiler))
            }
        } trailing: {
            DetailSection("Memory") {
                DetailRow("In use", Format.bytes(gpu.memoryInUse))
                DetailRow("Allocated", Format.bytes(gpu.memoryAllocated))
                if monitor.memory.total > 0 {
                    DetailRow(
                        "Share of system RAM", Format.percent(Double(gpu.memoryInUse) / Double(monitor.memory.total)))
                }
                DetailRow("Type", "Unified (shared with CPU)")
            }
            DetailSection("Hardware") {
                DetailRow("GPU", gpu.model ?? MachineInfo.chip)
                if let cores = ChipInfo.gpuCores { DetailRow("GPU cores", "\(cores)") }
                DetailRow(
                    "GPU restarts", gpu.recoveries == 0 ? "None" : "\(gpu.recoveries) since boot",
                    dot: gpu.recoveries == 0 ? .green : .orange)
                DetailRow("System thermal state", monitor.thermalState.label, dot: monitor.thermalState.color)
            }
        }
    }

    private func subtitle(_ gpu: GPUStats) -> String {
        let name = gpu.model ?? MachineInfo.chip
        return ChipInfo.gpuCores.map { "\(name) · \($0) cores" } ?? name
    }
}
