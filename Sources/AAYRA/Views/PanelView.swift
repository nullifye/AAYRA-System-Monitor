import ServiceManagement
import SwiftUI

struct PanelView: View {
    let monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 6) {
            HeaderView(monitor: monitor)
            CPUCard(monitor: monitor)
            StorageCard(disk: monitor.disk)
            MemoryCard(memory: monitor.memory)
            if let battery = monitor.battery {
                BatteryCard(battery: battery)
            }
            NetworkCard(monitor: monitor)
            FooterView()
        }
        .padding(10)
        .frame(width: Metrics.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Header

private struct HeaderView: View {
    let monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 6) {
            Text(MachineInfo.productName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text("Up \(Format.uptime(since: monitor.bootDate))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 3)
        .help("\(MachineInfo.chip) · \(MachineInfo.osVersion)")
    }
}

// MARK: - CPU

private struct CPUCard: View {
    let monitor: SystemMonitor

    var body: some View {
        let cpu = monitor.cpu
        Card(symbol: "cpu", tint: Palette.cpu) {
            MeterHeader(title: "CPU", value: Format.percent(cpu.total)) {
                Sparkline(values: monitor.cpuHistory, color: Palette.cpu)
            }
        } details: {
            HStack(spacing: 10) {
                Stat(label: "User", value: Format.percent(cpu.user), dot: Palette.cpu)
                Stat(label: "System", value: Format.percent(cpu.system), dot: Palette.cpuSystem)
                Stat(label: "Load", value: String(format: "%.2f", cpu.loadAverage.0))
                Spacer(minLength: 0)
                CoreBars(loads: cpu.perCore, tint: Palette.cpu)
                    .help(coreSummary)
            }
        }
    }

    private var coreSummary: String {
        let p = monitor.performanceCores, e = monitor.efficiencyCores
        let cores = p > 0 && e > 0 ? "\(p) Performance + \(e) Efficiency cores" : "\(monitor.cpu.perCore.count) cores"
        let l = monitor.cpu.loadAverage
        return cores + String(format: "\nLoad average %.2f · %.2f · %.2f", l.0, l.1, l.2)
    }
}

// MARK: - Storage

private struct StorageCard: View {
    let disk: DiskStats

    var body: some View {
        Card(symbol: "internaldrive.fill", tint: Palette.storage) {
            MeterHeader(title: "Storage", value: "\(Format.diskBytes(disk.available)) free") {
                UsageBar(fraction: disk.usedFraction, warning: 0.9, critical: 0.95, tint: Palette.storage)
            }
        } details: {
            HStack(spacing: 10) {
                Text(disk.volumeName)
                Spacer(minLength: 0)
                Stat(label: "Used", value: "\(Format.diskBytes(disk.used)) of \(Format.diskBytes(disk.total))")
            }
        }
    }
}

// MARK: - Memory

private struct MemoryCard: View {
    let memory: MemoryStats

    var body: some View {
        Card(symbol: "memorychip", tint: Palette.memory) {
            MeterHeader(title: "Memory", value: "\(Format.bytes(memory.used)) / \(Format.bytes(memory.total))") {
                UsageBar(fraction: memory.usedFraction, color: barColor)
            }
        } details: {
            // Two rows in three equal, left-aligned columns.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    column(Stat(label: "App", value: Format.bytes(memory.app)))
                    column(Stat(label: "Wired", value: Format.bytes(memory.wired)))
                    column(Stat(label: "Compr.", value: Format.bytes(memory.compressed)))
                }
                GridRow {
                    column(Stat(label: "Cached", value: Format.bytes(memory.cached)))
                    column(Stat(label: "Swap", value: Format.bytes(memory.swapUsed)))
                    column(Stat(label: "", value: pressureText, dot: pressureColor))
                }
            }
        }
    }

    /// Section colour normally; follows memory pressure when the system is under strain.
    private var barColor: Color {
        switch memory.pressure {
        case .normal: Palette.memory
        case .warning: .orange
        case .critical: .red
        }
    }

    private func column(_ stat: Stat) -> some View {
        stat.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    private var pressureText: String {
        switch memory.pressure {
        case .normal: "Normal Pressure"
        case .warning: "High Pressure"
        case .critical: "Critical Pressure"
        }
    }
}

// MARK: - Battery

private struct BatteryCard: View {
    let battery: BatteryStats

    var body: some View {
        Card(symbol: symbol, tint: tint) {
            MeterHeader(title: "Battery", value: Format.percent(battery.charge)) {
                UsageBar(fraction: battery.charge, color: tint)
            }
        } details: {
            HStack(spacing: 10) {
                Text(stateText)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Stat(label: "Temp", value: battery.temperatureC.map(Format.temperature) ?? "—")
            }
            HStack(spacing: 10) {
                Stat(label: "Max Capacity", value: battery.health.map { Format.percent($0) } ?? "—")
                Spacer(minLength: 0)
                Stat(label: "Condition", value: battery.condition ?? "—", dot: conditionColor)
            }
            HStack(spacing: 10) {
                Stat(label: "Cycles", value: cycleText)
                Spacer(minLength: 0)
                Stat(label: "Capacity", value: capacityText)
            }
        }
    }

    private var symbol: String {
        if battery.state == .charging || battery.state == .charged { return "battery.100percent.bolt" }
        switch battery.charge {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var tint: Color {
        if battery.isPluggedIn { return Palette.battery }
        return battery.charge <= 0.1 ? .red : battery.charge <= 0.2 ? .orange : Palette.battery
    }

    /// State and time in one short phrase, e.g. "6h 35m left" or "Charging · 1h 10m".
    private var stateText: String {
        let adapter = battery.adapterWatts.map { " · \($0)W adapter" } ?? ""
        return baseStateText + (battery.isPluggedIn ? adapter : "")
    }

    private var baseStateText: String {
        switch battery.state {
        case .onBattery:
            return battery.minutesToEmpty.map { "\(Format.minutes($0)) left" } ?? "Calculating…"
        case .charging:
            return "Charging" + (battery.minutesToFull.map { " · \(Format.minutes($0))" } ?? "")
        case .charged:
            return "Charged"
        case .pluggedNotCharging:
            return "Not Charging"
        }
    }

    private var cycleText: String {
        guard let cycles = battery.cycleCount else { return "—" }
        return battery.designCycles.map { "\(cycles) / \($0)" } ?? "\(cycles)"
    }

    private var capacityText: String {
        guard let now = battery.currentCapacity_mAh, let design = battery.designCapacity_mAh else { return "—" }
        return "\(now) / \(design) mAh"
    }

    private var conditionColor: Color {
        switch battery.condition?.lowercased() {
        case "good", "normal": .green
        case nil: .secondary
        default: .orange   // "Fair", "Service Recommended", …
        }
    }
}

// MARK: - Network

private struct NetworkCard: View {
    let monitor: SystemMonitor
    @State private var copiedValue: String?

    var body: some View {
        let net = monitor.network
        Card(symbol: symbol, tint: net.isConnected ? Palette.network : .gray) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsPermissionButton {
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
            }
            .help(net.interfaceName.map { "\(net.interfaceKind) (\($0))" } ?? "Offline")
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                rate("arrow.down", net.downloadBytesPerSec, Palette.download)
                rate("arrow.up", net.uploadBytesPerSec, Palette.upload)
            }
        } details: {
            DualSparkline(download: monitor.downloadHistory, upload: monitor.uploadHistory, height: 16)
            HStack(spacing: 6) {
                address("Local", net.localIPv4 ?? net.localIPv6)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    address("Public", monitor.publicIP, loading: monitor.isFetchingPublicIP, alignment: .trailing)
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
        }
    }

    private var title: String {
        let net = monitor.network
        guard net.isConnected else { return "Offline" }
        return monitor.wifiName ?? net.interfaceKind
    }

    private var showsPermissionButton: Bool {
        monitor.network.interfaceKind == "Wi-Fi" && monitor.wifiName == nil && monitor.wifiAccess != .granted
    }

    private var symbol: String {
        switch monitor.network.interfaceKind {
        case "Wi-Fi": "wifi"
        case "Ethernet": "cable.connector"
        case "Offline": "wifi.slash"
        default: "network"
        }
    }

    private func rate(_ symbol: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(Format.rate(value))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
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

private struct FooterView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            iconButton("Activity Monitor", symbol: "waveform.path.ecg") { SystemActions.openActivityMonitor() }
            iconButton("Quit AAYRA", symbol: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
        .padding(.horizontal, 3)
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.medium))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}
