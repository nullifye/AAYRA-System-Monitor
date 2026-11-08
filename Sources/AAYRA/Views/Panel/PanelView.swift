import SwiftUI

// The floating panel: header, one card per section and the footer, stacked like Notification Center.

struct PanelView: View {
    let monitor: SystemMonitor
    /// Side the detail panels open on: whichever has more room on screen.
    var detailEdge: Edge = .leading
    /// Reports the content size so the floating window can match it.
    var onResize: ((CGSize) -> Void)?
    @State private var openDetail: DetailKind?
    @AppStorage(AppSettings.Key.showsSection(.cpu)) private var showCPU = true
    @AppStorage(AppSettings.Key.showsSection(.gpu)) private var showGPU = false  // off by default
    @AppStorage(AppSettings.Key.showsSection(.storage)) private var showStorage = true
    @AppStorage(AppSettings.Key.showsSection(.memory)) private var showMemory = true
    @AppStorage(AppSettings.Key.showsSection(.battery)) private var showBattery = true
    @AppStorage(AppSettings.Key.showsSection(.network)) private var showNetwork = true

    var body: some View {
        FloatingStack {
            HeaderView(monitor: monitor)
            if showCPU { cpuCard }
            if showGPU, monitor.gpu != nil { gpuCard }
            if showStorage { storageCard }
            if showMemory { memoryCard }
            if showBattery, let battery = monitor.battery { batteryCard(battery) }
            if showNetwork { networkCard }
            FooterView()
        }
        // Margin around the cards leaves room for their shadows inside the transparent window.
        .padding(Metrics.floatMargin)
        .frame(width: Metrics.panelWidth + Metrics.floatMargin * 2)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: \.size) { onResize?($0) }
    }

    private var cpuCard: some View {
        CPUCard(monitor: monitor)
            .detailPopover(.cpu, selection: $openDetail, edge: detailEdge, tint: Palette.cpu) {
                CPUDetail(monitor: monitor)
            }
    }

    private var gpuCard: some View {
        GPUCard(monitor: monitor)
            .detailPopover(.gpu, selection: $openDetail, edge: detailEdge, tint: Palette.gpu) {
                GPUDetail(monitor: monitor)
            }
    }

    private var storageCard: some View {
        StorageCard(disk: monitor.disk, io: monitor.diskIO, volumes: monitor.volumes)
            .detailPopover(.storage, selection: $openDetail, edge: detailEdge, tint: Palette.storage) {
                StorageDetail(monitor: monitor)
            }
    }

    private var memoryCard: some View {
        MemoryCard(memory: monitor.memory)
            .detailPopover(.memory, selection: $openDetail, edge: detailEdge, tint: Palette.memory) {
                MemoryDetail(memory: monitor.memory, topProcesses: monitor.topProcesses)
            }
    }

    private func batteryCard(_ battery: BatteryStats) -> some View {
        BatteryCard(battery: battery, drainCause: monitor.batteryDrainInsight.cause)
            .detailPopover(.battery, selection: $openDetail, edge: detailEdge, tint: battery.tint) {
                // Read through the monitor so the open panel keeps updating.
                if let battery = monitor.battery {
                    BatteryDetail(
                        battery: battery, lowPowerMode: monitor.isLowPowerMode,
                        drainCause: monitor.batteryDrainInsight.cause)
                }
            }
    }

    private var networkCard: some View {
        NetworkCard(monitor: monitor)
            .detailPopover(
                .network, selection: $openDetail, edge: detailEdge,
                tint: monitor.network.isConnected ? Palette.network : .gray
            ) {
                NetworkDetail(monitor: monitor)
            }
    }
}

/// Cards stacked with a gap, like Notification Center. On macOS 26+ the glass tiles share
/// one container so they render together efficiently, without merging into each other.
private struct FloatingStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let stack = VStack(spacing: 8) { content() }
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) { stack }
        } else {
            stack
        }
    }
}
