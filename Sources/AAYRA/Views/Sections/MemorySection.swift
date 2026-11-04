import SwiftUI

// Memory: the card in the panel and its detail panel.

struct MemoryCard: View {
    let memory: MemoryStats

    var body: some View {
        Card(symbol: "memorychip", tint: Palette.memory) {
            MeterHeader(
                title: "Memory", value: Format.memoryShort(memory.used),
                suffix: "of \(Format.bytes(memory.total))")
        } details: {
            StackedBar(
                segments: [
                    .init(value: share(memory.app), color: Palette.memory),
                    .init(value: share(memory.wired), color: Palette.memoryWired),
                    .init(value: share(memory.compressed), color: Palette.memoryCompressed),
                    .init(value: share(memory.cached), color: Palette.memoryCached),
                ], height: 8)
            StatRow(stats: [
                Stat(label: "App", value: Format.memoryShort(memory.app), dot: Palette.memory),
                Stat(label: "Wired", value: Format.memoryShort(memory.wired), dot: Palette.memoryWired),
                Stat(label: "Compr.", value: Format.memoryShort(memory.compressed), dot: Palette.memoryCompressed),
            ])
        }
    }

    private func share(_ bytes: UInt64) -> Double {
        memory.total > 0 ? Double(bytes) / Double(memory.total) : 0
    }
}

struct MemoryDetail: View {
    /// The one app in Top Processes that's expanded, if any.
    @State private var expandedProcess: String?
    let memory: MemoryStats
    let topProcesses: [ProcessMemory]

    var body: some View {
        DetailPanel(
            symbol: "memorychip", tint: Palette.memory, title: "Memory", subtitle: subtitle,
            actions: [.activityMonitor]
        ) {
            DetailSection("Usage") {
                StackedBar(
                    segments: [
                        .init(value: share(memory.app), color: Palette.memory),
                        .init(value: share(memory.wired), color: Palette.memoryWired),
                        .init(value: share(memory.compressed), color: Palette.memoryCompressed),
                        .init(value: share(memory.cached), color: Palette.memoryCached),
                    ], height: 8
                )
                .padding(.vertical, 3)
                DetailRow("App", Format.bytes(memory.app), dot: Palette.memory)
                DetailRow("Wired", Format.bytes(memory.wired), dot: Palette.memoryWired)
                DetailRow("Compressed", Format.bytes(memory.compressed), dot: Palette.memoryCompressed)
                DetailRow("Cached files", Format.bytes(memory.cached), dot: Palette.memoryCached)
                DetailRow("Free", Format.bytes(memory.free))
            }
            DetailSection("Hardware") {
                DetailRow("Installed", Format.bytes(memory.total))
                if let type = MemoryHardware.type { DetailRow("Type", type) }
                if let vendor = MemoryHardware.vendor { DetailRow("Vendor", vendor) }
            }
            DetailSection("Pressure & Swap") {
                DetailRow("Pressure", memory.pressure.name, dot: memory.pressure.color)
                if let level = memory.freePercent { DetailRow("Memory level", "\(level)% free") }
                DetailRow(
                    "Swap used",
                    memory.swapTotal == 0
                        ? "None"
                        : "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))")
                DetailRow("Swap-ins", Format.compactCount(memory.swapIns))
                DetailRow("Swap-outs", Format.compactCount(memory.swapOuts))
            }
        } trailing: {
            DetailSection("Activity") {
                DetailRow("Compressions", Format.compactCount(memory.compressions))
                DetailRow("Decompressions", Format.compactCount(memory.decompressions))
                DetailRow("Page-ins", Format.compactCount(memory.pageIns))
                DetailRow("Page-outs", Format.compactCount(memory.pageOuts))
            }
            DetailSection("Top Processes") {
                if topProcesses.isEmpty {
                    EmptyRow(text: "Measuring…")
                } else {
                    ForEach(topProcesses) { process in
                        ProcessRow(
                            name: process.name, value: Format.bytes(process.footprint),
                            fraction: share(process.footprint), tint: Palette.memory, count: process.count,
                            members: process.members.map {
                                .init(id: $0.id, name: $0.name, value: Format.bytes(UInt64($0.value)))
                            },
                            isExpanded: expandedProcess == process.id,
                            onToggle: { expandedProcess = expandedProcess == process.id ? nil : process.id })
                    }
                }
            }
        }
    }

    private var subtitle: String {
        "\(Format.bytes(memory.used)) used of \(Format.bytes(memory.total))"
    }

    private func share(_ bytes: UInt64) -> Double {
        memory.total > 0 ? Double(bytes) / Double(memory.total) : 0
    }
}

extension MemoryStats.Pressure {
    var name: String {
        switch self {
        case .normal: "Normal"
        case .warning: "High"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
