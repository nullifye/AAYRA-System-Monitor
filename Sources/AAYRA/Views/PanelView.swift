import SwiftUI

struct PanelView: View {
    let monitor: SystemMonitor
    /// Side the detail panels open on: whichever has more room on screen.
    var detailEdge: Edge = .leading
    /// Reports the content size so the floating window can match it.
    var onResize: ((CGSize) -> Void)?
    @State private var openDetail: DetailKind?
    @AppStorage(AppSettings.Key.showsSection(.cpu)) private var showCPU = true
    @AppStorage(AppSettings.Key.showsSection(.gpu)) private var showGPU = true
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
        StorageCard(disk: monitor.disk, io: monitor.diskIO)
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
        BatteryCard(battery: battery)
            .detailPopover(.battery, selection: $openDetail, edge: detailEdge, tint: battery.tint) {
                // Read through the monitor so the open panel keeps updating.
                if let battery = monitor.battery {
                    BatteryDetail(battery: battery, lowPowerMode: monitor.isLowPowerMode)
                }
            }
    }

    private var networkCard: some View {
        NetworkCard(monitor: monitor)
            .detailPopover(.network, selection: $openDetail, edge: detailEdge,
                           tint: monitor.network.isConnected ? Palette.network : .gray) {
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

// MARK: - Header

private struct HeaderView: View {
    let monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 6) {
            Text(MachineInfo.productName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text("Up \(Format.uptime(since: monitor.bootDate))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .cardBackground(floating: true)
        .help("\(MachineInfo.chip) · \(MachineInfo.osVersion)")
    }
}

// MARK: - CPU

private struct CPUCard: View {
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

// MARK: - GPU

private struct GPUCard: View {
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

// MARK: - Storage

private struct StorageCard: View {
    let disk: DiskStats
    let io: DiskIO

    var body: some View {
        Card(symbol: "internaldrive.fill", tint: Palette.storage) {
            MeterHeader(title: "Storage", value: Format.diskShort(disk.available), suffix: "free")
        } details: {
            StackedBar(segments: [
                .init(value: share(disk.used), color: Palette.storage),
                .init(value: share(disk.purgeable), color: Palette.storagePurgeable),
            ], height: 8)
            StatRow(stats: [
                Stat(label: "Used", value: Format.diskShort(disk.used), dot: Palette.storage),
                Stat(label: "Purge.", value: Format.diskShort(disk.purgeable), dot: Palette.storagePurgeable),
                Stat(label: "Total", value: Format.diskShort(disk.total)),
            ])
            // Live disk activity, in the same columns as the line above.
            StatRow(stats: [
                Stat(label: "Read", value: Format.compactRate(io.readBytesPerSec), dot: Palette.diskRead),
                Stat(label: "Write", value: Format.compactRate(io.writeBytesPerSec), dot: Palette.diskWrite),
                Stat(label: "", value: ""),
            ])
        }
    }

    private func share(_ bytes: Int64) -> Double {
        disk.total > 0 ? Double(bytes) / Double(disk.total) : 0
    }
}

// MARK: - Memory

private struct MemoryCard: View {
    let memory: MemoryStats

    var body: some View {
        Card(symbol: "memorychip", tint: Palette.memory) {
            MeterHeader(title: "Memory", value: Format.memoryShort(memory.used),
                        suffix: "of \(Format.bytes(memory.total))")
        } details: {
            StackedBar(segments: [
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

// MARK: - Battery

private struct BatteryCard: View {
    let battery: BatteryStats

    var body: some View {
        let tint = battery.tint, maxCapacity = battery.maxCapacity
        Card(symbol: battery.symbol, tint: tint) {
            MeterHeader(title: "Battery", value: Format.percent(battery.charge))
        } details: {
            StackedBar(segments: [
                .init(value: battery.charge * maxCapacity, color: tint),
                .init(value: (1 - battery.charge) * maxCapacity, color: .clear),
                .init(value: 1 - maxCapacity, color: Palette.batteryWorn),
            ], height: 8)
            HStack(spacing: 10) {
                Text(stateText)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Stat(label: "Temp", value: battery.temperatureC.map(Format.temperature) ?? "—")
            }
            HStack(spacing: 10) {
                Stat(label: "Cycles", value: battery.cycleText)
                Spacer(minLength: 0)
                Stat(label: "Capacity", value: battery.capacityText)
            }
        }
    }

    /// The card adds the adapter wattage when plugged in, e.g. "Charging · 1h 10m · 96W adapter".
    private var stateText: String {
        let adapter = battery.adapterWatts.map { " · \($0)W adapter" } ?? ""
        return battery.stateText + (battery.isPluggedIn ? adapter : "")
    }
}

// MARK: - Network

private struct NetworkCard: View {
    let monitor: SystemMonitor
    @State private var copiedValue: String?
    @AppStorage(AppSettings.Key.fetchPublicIP) private var fetchPublicIP = true
    #if DEBUG
    @Environment(\.isSnapshot) private var isSnapshot
    #else
    private let isSnapshot = false   // screenshots are a debug-only feature
    #endif

    var body: some View {
        let net = monitor.network
        Card(symbol: net.symbol, tint: net.isConnected ? Palette.network : .gray) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsPermissionButton && !isSnapshot {
                    Button {
                        monitor.requestWiFiNameAccess()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(monitor.wifiAccess == .denied
                          ? "Allow Location Services in System Settings to show the Wi-Fi name"
                          : "Show the Wi-Fi name (macOS asks for Location Services access)")
                }
                if net.isVPNConnected {
                    Text("VPN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.network.gradient, in: Capsule())
                        .help("VPN connected (\(net.vpnInterface ?? ""))")
                        .accessibilityLabel("VPN connected")
                }
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rate("arrow.down", net.downloadBytesPerSec, Palette.download)
                rate("arrow.up", net.uploadBytesPerSec, Palette.upload)
            }
        } details: {
            DualSparkline(download: monitor.downloadHistory, upload: monitor.uploadHistory, height: 22)
            HStack(spacing: 6) {
                address("Local", isSnapshot ? "192.168.1.20" : net.localIPv4 ?? net.localIPv6)
                Spacer(minLength: 4)
                if fetchPublicIP { publicAddress }
            }
        }
    }

    private var publicAddress: some View {
        HStack(spacing: 2) {
            address("Public", isSnapshot ? "203.0.113.42" : monitor.publicIP,
                    loading: monitor.isFetchingPublicIP, alignment: .trailing)
            Button {
                monitor.refreshPublicIP(force: true)
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption2)
            }
            .buttonStyle(.plain)
            .disabled(monitor.isFetchingPublicIP)
            .help("Refresh public IP")
        }
    }

    private var title: String {
        let net = monitor.network
        guard net.isConnected else { return "Offline" }
        if isSnapshot, monitor.wifiName != nil { return "Home Wi-Fi" }
        return monitor.wifiName ?? net.interfaceKind
    }

    private var showsPermissionButton: Bool {
        monitor.network.interfaceKind == "Wi-Fi" && monitor.wifiName == nil && monitor.wifiAccess != .granted
    }

    private func rate(_ symbol: String, _ value: Double, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.callout.weight(.bold))
                .foregroundStyle(color)
            BigValue(Format.rate(value), size: 18)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func address(_ label: String, _ value: String?, loading: Bool = false,
                         alignment: Alignment = .leading) -> some View {
        HStack(spacing: 3) {
            Text(label)
            if loading && value == nil {
                ProgressView().controlSize(.mini)
            } else if let value {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copiedValue = value
                    Task {
                        try? await Task.sleep(for: .seconds(1.3))
                        if copiedValue == value { copiedValue = nil }
                    }
                } label: {
                    // Turns bold for a moment to confirm the copy. A hidden bold copy reserves
                    // the width so nothing shifts, and the change is instant (no animation).
                    ZStack(alignment: alignment) {
                        Text(value).fontWeight(.bold).hidden()
                        Text(value).fontWeight(copiedValue == value ? .bold : .regular)
                    }
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .transaction { $0.animation = nil }
                }
                .buttonStyle(.plain)
                .help("Click to copy \(label.lowercased()) IP")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Footer

/// The AAYRA wordmark in the regular system font and a solid colour, with a bevel: a bright inner
/// edge along the top-left of each letter, a dark inner edge along the bottom-right, and a soft drop
/// shadow, so the letters look raised from the tile.
private struct BevelWordmark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let face = dark ? Color(white: 0.85) : Color(white: 0.3)
        Text("AAYRA")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(
                face
                    .shadow(.inner(color: .white.opacity(dark ? 0.9 : 0.7), radius: 0.4, x: 0.6, y: 0.9))
                    .shadow(.inner(color: .black.opacity(dark ? 0.55 : 0.6), radius: 0.4, x: -0.6, y: -0.9))
                    .shadow(.drop(color: .black.opacity(dark ? 0.45 : 0.25), radius: 0.8, x: 0.3, y: 0.8))
            )
            .accessibilityLabel("AAYRA")
    }
}

private struct FooterView: View {
    private let version = AppInfo.version

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                BevelWordmark()
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer()
            iconButton("Settings", symbol: "gearshape") { SettingsWindow.show() }
                .keyboardShortcut(",")
            iconButton("Activity Monitor", symbol: "waveform.path.ecg") { SystemActions.openActivityMonitor() }
            iconButton("Quit AAYRA", symbol: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .cardBackground(floating: true)
    }

    /// Round glass buttons on macOS 26+ (controls are where Liquid Glass belongs), plain icons before.
    @ViewBuilder
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.medium))
                .frame(width: 18, height: 18)
        }
        if #available(macOS 26, *) {
            button
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(title)
                .accessibilityLabel(title)
        } else {
            button
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(title)
                .accessibilityLabel(title)
        }
    }
}
