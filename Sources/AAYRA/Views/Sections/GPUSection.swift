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

    var body: some View {
        let gpu = monitor.gpu ?? GPUStats()
        let history = monitor.gpuHistory
        let span = Format.span(monitor.historySpan)
        DetailPanel(symbol: Palette.gpuSymbol, tint: Palette.gpu, title: "GPU", subtitle: subtitle(gpu),
                    actions: [.activityMonitor]) {
            DetailSection("Usage") {
                Sparkline(values: history, color: Palette.gpu, height: 34)
                    .padding(.vertical, 2)
                DetailRow("Overall", Format.percent(gpu.device), dot: Palette.gpu)
                DetailRow("Renderer (pixels)", Format.percent(gpu.renderer))
                DetailRow("Tiler (geometry)", Format.percent(gpu.tiler))
                DetailRow("Peak (\(span))", Format.percent(history.max() ?? 0))
            }
        } trailing: {
            DetailSection("Memory") {
                DetailRow("In use", Format.bytes(gpu.memoryInUse))
                DetailRow("Allocated", Format.bytes(gpu.memoryAllocated))
                DetailRow("Type", "Unified (shared with CPU)")
            }
            DetailSection("Hardware") {
                DetailRow("GPU", gpu.model ?? MachineInfo.chip)
                if let cores = ChipInfo.gpuCores { DetailRow("GPU cores", "\(cores)") }
                DetailRow("GPU restarts", gpu.recoveries == 0 ? "None" : "\(gpu.recoveries) since boot",
                          dot: gpu.recoveries == 0 ? .green : .orange)
            }
        }
    }

    private func subtitle(_ gpu: GPUStats) -> String {
        let name = gpu.model ?? MachineInfo.chip
        return ChipInfo.gpuCores.map { "\(name) · \($0) cores" } ?? name
    }
}
