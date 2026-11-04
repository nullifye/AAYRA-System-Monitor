import ServiceManagement
import SwiftUI

struct PanelView: View {
    let monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 6) {
            HeaderView(monitor: monitor)
            CPUCard(monitor: monitor)
            StorageCard(disk: monitor.disk, ssd: monitor.ssd)
            MemoryCard(memory: monitor.memory, topProcesses: monitor.topProcesses)
            if let battery = monitor.battery {
                BatteryCard(battery: battery, lowPowerMode: monitor.isLowPowerMode)
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
            }
        }
        .help(tooltip)
    }

    /// Extra details shown when hovering the CPU card.
    private var tooltip: String {
        let cpu = monitor.cpu
        func pct(_ v: Double) -> String { Format.percent(v) }
        func kb(_ bytes: Int?) -> String? { bytes.map { "\($0 / 1024) KB" } }
        func mb(_ bytes: Int?) -> String? { bytes.map { "\($0 / 1_048_576) MB" } }
        var lines: [String] = []

        lines.append("Chip: \(MachineInfo.chip)" + (ChipInfo.model.map { " · \($0)" } ?? ""))
        let p = monitor.performanceCores, e = monitor.efficiencyCores
        var cores = p > 0 && e > 0 ? "\(p + e) CPU (\(p) Performance + \(e) Efficiency)" : "\(cpu.perCore.count) CPU"
        if let gpu = ChipInfo.gpuCores { cores += " · \(gpu) GPU" }
        lines.append("Cores: " + cores)
        let pc = ChipInfo.performanceCache, ec = ChipInfo.efficiencyCache
        if let pl2 = mb(pc.l2), let el2 = mb(ec.l2) {
            lines.append("L2 cache: \(pl2) (P) · \(el2) (E)")
        }
        if let pi = kb(pc.l1i), let pd = kb(pc.l1d), let ei = kb(ec.l1i), let ed = kb(ec.l1d) {
            lines.append("L1 cache: \(pi) + \(pd) (P) · \(ei) + \(ed) (E)  [instr + data, per core]")
        }

        lines.append("Usage: \(pct(cpu.total)) (user \(pct(cpu.user)) · system \(pct(cpu.system)) · "
                     + "idle \(pct(max(0, 1 - cpu.total))))")
        let clusters = ChipInfo.coreClusters
        if clusters.count == cpu.perCore.count, !clusters.isEmpty {
            func group(_ type: String) -> [Double] { zip(clusters, cpu.perCore).filter { $0.0 == type }.map(\.1) }
            let pLoads = group("P"), eLoads = group("E")
            func avg(_ v: [Double]) -> String { v.isEmpty ? "—" : pct(v.reduce(0, +) / Double(v.count)) }
            func list(_ v: [Double]) -> String { v.map { String(Int(($0 * 100).rounded())) }.joined(separator: " ") }
            lines.append("Performance cores: \(avg(pLoads)) avg  [\(list(pLoads))]")
            lines.append("Efficiency cores: \(avg(eLoads)) avg  [\(list(eLoads))]")
        }
        let l = cpu.loadAverage
        lines.append(String(format: "Load average: %.2f · %.2f · %.2f  (1 · 5 · 15 min)", l.0, l.1, l.2))
        lines.append("Thermal state: " + thermalText)

        var system: [String] = []
        if monitor.processCount > 0 { system.append("\(monitor.processCount) processes") }
        if let boot = monitor.bootDate {
            system.append("up \(Format.uptime(since: boot)) (since \(boot.formatted(date: .abbreviated, time: .shortened)))")
        }
        if !system.isEmpty { lines.append(system.joined(separator: " · ").capitalizedFirst) }
        if let kernel = ChipInfo.kernel {
            lines.append("Kernel: Darwin \(kernel)" + (ChipInfo.build.map { " (\($0))" } ?? ""))
        }

        lines.append("Top processes:")
        if monitor.topCPUProcesses.isEmpty {
            lines.append("   Measuring…")
        } else {
            for process in monitor.topCPUProcesses {
                lines.append("   \(process.name) — " + String(format: "%.1f%%", process.percent))
            }
        }
        return lines.joined(separator: "\n")
    }

    private var thermalText: String {
        switch monitor.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair (warm)"
        case .serious: "Serious (throttling)"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

// MARK: - Storage

private struct StorageCard: View {
    let disk: DiskStats
    let ssd: SSDHealth?

    var body: some View {
        Card(symbol: "internaldrive.fill", tint: Palette.storage) {
            MeterHeader(title: "Storage", value: "\(Format.diskBytes(disk.available)) free") {
                StackedBar(segments: [
                    .init(value: share(disk.used), color: Palette.storage),
                    .init(value: share(disk.purgeable), color: Palette.storagePurgeable),
                ])
            }
        } details: {
            // Two rows in three equal, left-aligned columns (same grid as Memory).
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    column(Stat(label: "Used", value: Format.diskShort(disk.used), dot: Palette.storage))
                    column(Stat(label: "Purge.", value: Format.diskShort(disk.purgeable), dot: Palette.storagePurgeable))
                    column(Stat(label: "Total", value: Format.diskShort(disk.total)))
                }
                if let ssd {
                    GridRow {
                        column(Stat(label: "Health", value: Format.percent(ssd.health), dot: healthColor(ssd)))
                        column(Stat(label: "Temp", value: ssd.temperatureC.map(Format.temperature) ?? "—"))
                        column(Stat(label: "Written", value: Format.diskShort(Int64(clamping: ssd.bytesWritten))))
                    }
                }
            }
        }
        .help(tooltip)
    }

    private func column(_ stat: Stat) -> some View {
        stat.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthColor(_ ssd: SSDHealth) -> Color {
        if ssd.condition == "Check Drive" { return .red }
        return ssd.health >= 0.8 ? .green : ssd.health >= 0.5 ? .orange : .red
    }

    /// Extra details shown when hovering the storage card.
    private var tooltip: String {
        var lines: [String] = []
        let volume = [disk.volumeName, disk.fileSystem,
                      disk.isEncrypted.map { $0 ? "FileVault On" : "FileVault Off" }].compactMap { $0 }
        lines.append("Volume: " + volume.joined(separator: " · "))
        lines.append("Available: \(Format.diskBytes(disk.available)) "
                     + "(free \(Format.diskBytes(disk.free)) + purgeable \(Format.diskBytes(disk.purgeable)))")

        guard let ssd else { return lines.joined(separator: "\n") }
        let info = ssd.info
        let drive = [info.model, info.capacityBytes.map { Format.diskBytes($0) }, info.interconnect]
            .compactMap { $0 }
        if !drive.isEmpty { lines.append("Drive: " + drive.joined(separator: " · ")) }
        if let serial = info.serial { lines.append("Serial: \(serial)") }
        if let firmware = info.firmware { lines.append("Firmware: \(firmware)") }
        lines.append("SSD health: \(Format.percent(ssd.health)) (\(ssd.condition)) · "
                     + "Spare \(ssd.availableSpare)% (min \(ssd.availableSpareThreshold)%)")
        if let t = ssd.temperatureC { lines.append("Temperature: \(Format.temperature(celsius: t))") }
        lines.append("Data written: \(Format.diskShort(Int64(clamping: ssd.bytesWritten))) · "
                     + "read \(Format.diskShort(Int64(clamping: ssd.bytesRead)))")
        let days = Double(ssd.powerOnHours) / 24
        lines.append("Power-on: \(ssd.powerOnHours.formatted()) h (\(Int(days.rounded())) days) · "
                     + "\(ssd.powerCycles.formatted()) power cycles")
        lines.append("Unsafe shutdowns: \(ssd.unsafeShutdowns.formatted()) · Media errors: \(ssd.mediaErrors.formatted())")
        return lines.joined(separator: "\n")
    }

    private func share(_ bytes: Int64) -> Double {
        disk.total > 0 ? Double(bytes) / Double(disk.total) : 0
    }
}

// MARK: - Memory

private struct MemoryCard: View {
    let memory: MemoryStats
    let topProcesses: [ProcessMemory]

    var body: some View {
        Card(symbol: "memorychip", tint: Palette.memory) {
            MeterHeader(title: "Memory", value: "\(Format.bytes(memory.used)) / \(Format.bytes(memory.total))") {
                StackedBar(segments: [
                    .init(value: share(memory.app), color: Palette.memory),
                    .init(value: share(memory.wired), color: Palette.memoryWired),
                    .init(value: share(memory.compressed), color: Palette.memoryCompressed),
                    .init(value: share(memory.cached), color: Palette.memoryCached),
                ])
            }
        } details: {
            // Two rows in three equal, left-aligned columns.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    column(Stat(label: "App", value: Format.bytes(memory.app), dot: Palette.memory))
                    column(Stat(label: "Wired", value: Format.bytes(memory.wired), dot: Palette.memoryWired))
                    column(Stat(label: "Compr.", value: Format.bytes(memory.compressed), dot: Palette.memoryCompressed))
                }
                GridRow {
                    column(Stat(label: "Cached", value: Format.bytes(memory.cached), dot: Palette.memoryCached))
                    column(Stat(label: "Swap", value: Format.bytes(memory.swapUsed)))
                    column(Stat(label: "", value: pressureText, dot: pressureColor))
                }
            }
        }
        .help(tooltip)
    }

    /// Extra details shown when hovering the memory card.
    private var tooltip: String {
        func count(_ n: UInt64) -> String { n.formatted(.number.notation(.compactName)) }
        var lines: [String] = []
        let hardware = [Format.bytes(memory.total), MemoryHardware.type, MemoryHardware.vendor].compactMap { $0 }
        lines.append("Installed: " + hardware.joined(separator: " · "))
        lines.append("Used: \(Format.bytes(memory.used)) (app \(Format.bytes(memory.app)) + wired "
                     + "\(Format.bytes(memory.wired)) + compressed \(Format.bytes(memory.compressed)))")
        lines.append("Cached files: \(Format.bytes(memory.cached)) · Free: \(Format.bytes(memory.free))")
        lines.append("Pressure: \(pressureText.replacingOccurrences(of: " Pressure", with: ""))"
                     + (memory.freePercent.map { " · \($0)% free (system memory level)" } ?? ""))
        lines.append("Swap: \(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal)) · "
                     + "swap-ins \(count(memory.swapIns)) · swap-outs \(count(memory.swapOuts))")
        lines.append("Compressions: \(count(memory.compressions)) · decompressions \(count(memory.decompressions))")
        lines.append("Page-ins: \(count(memory.pageIns)) · page-outs \(count(memory.pageOuts))")
        if !topProcesses.isEmpty {
            lines.append("Top processes:")
            for process in topProcesses {
                lines.append("   \(process.name) — \(Format.bytes(process.footprint))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func share(_ bytes: UInt64) -> Double {
        memory.total > 0 ? Double(bytes) / Double(memory.total) : 0
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
    let lowPowerMode: Bool

    var body: some View {
        Card(symbol: symbol, tint: tint) {
            MeterHeader(title: "Battery", value: Format.percent(battery.charge)) {
                StackedBar(segments: [
                    .init(value: battery.charge * maxCapacity, color: tint),
                    .init(value: (1 - battery.charge) * maxCapacity, color: .clear),
                    .init(value: 1 - maxCapacity, color: Palette.batteryWorn),
                ])
            }
        } details: {
            HStack(spacing: 10) {
                Text(stateText)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Stat(label: "Temp", value: battery.temperatureC.map(Format.temperature) ?? "—")
            }
            HStack(spacing: 10) {
                Stat(label: "Max Capacity", value: battery.health.map { Format.percent($0) } ?? "—", dot: tint)
                Stat(label: "Worn", value: Format.percent(1 - maxCapacity), dot: Palette.batteryWorn)
                Spacer(minLength: 0)
                Stat(label: "Condition", value: battery.condition ?? "—", dot: conditionColor)
            }
            HStack(spacing: 10) {
                Stat(label: "Cycles", value: cycleText)
                Spacer(minLength: 0)
                Stat(label: "Capacity", value: capacityText)
            }
        }
        .help(hoverDetails)
    }

    /// Extra details shown when hovering the battery card.
    private var hoverDetails: String {
        func volts(_ mV: Int) -> String { String(format: "%.2f V", Double(mV) / 1000) }
        func amps(_ mA: Int) -> String { String(format: "%.2f A", Double(abs(mA)) / 1000) }
        var lines: [String] = []

        if let date = battery.manufactureDate {
            let when = date.formatted(.dateTime.day().month(.abbreviated).year())
            let age = Format.age(since: date)
            lines.append(battery.manufactureDateIsEstimate
                         ? "Manufactured: ≈ \(when) (estimated) · Age ≈ \(age)"
                         : "Manufactured: \(when) · Age \(age)")
        }
        lines.append("Manufacturer: \(battery.manufacturer ?? "Unknown")")
        if let serial = battery.serial { lines.append("Serial: \(serial)") }
        if let full = battery.fullChargeCapacity_mAh {
            lines.append("Full charge capacity: \(full) mAh" + (battery.designCapacity_mAh.map { " (design \($0) mAh)" } ?? ""))
        }
        if let remaining = battery.remaining_mAh, let max = battery.rawMax_mAh {
            lines.append("Remaining: \(remaining) of \(max) mAh")
        }

        var power: [String] = []
        if let watts = battery.powerWatts, abs(watts) >= 0.05 {
            let rate = String(format: "%.1f W", abs(watts))
            power.append(watts < 0 ? "Discharging at \(rate)" : "Charging at \(rate)")
        } else {
            power.append("Battery idle (0 W)")
        }
        if let load = battery.systemLoadWatts { power.append(String(format: "Mac drawing %.1f W", load)) }
        lines.append(power.joined(separator: " · "))

        if let mV = battery.voltage_mV {
            lines.append("Voltage: \(volts(mV))" + (battery.current_mA.map { " · Current: \($0) mA" } ?? ""))
        }
        if !battery.cellVoltages_mV.isEmpty {
            let cells = battery.cellVoltages_mV.map { String(format: "%.3f", Double($0) / 1000) }.joined(separator: " / ")
            let spread = (battery.cellVoltages_mV.max() ?? 0) - (battery.cellVoltages_mV.min() ?? 0)
            lines.append("Cells: \(cells) V (spread \(spread) mV)")
        }
        if let low = battery.dailyMinSoc, let high = battery.dailyMaxSoc {
            lines.append("Today's charge range: \(low)–\(high)%")
        }
        var adapter = "Power adapter: " + adapterStatus
        if let input = battery.adapterInputWatts { adapter += String(format: " · drawing %.1f W", input) }
        lines.append(adapter)
        lines.append("Low Power Mode: " + (lowPowerMode ? "On" : "Off"))

        // Lifetime record from the fuel gauge.
        var lifetime: [String] = []
        if let low = battery.lifetimeMinTempC, let high = battery.lifetimeMaxTempC {
            lifetime.append("Temperature: \(low)–\(high) °C"
                            + (battery.lifetimeAvgTempC.map { String(format: " (avg %.1f °C)", $0) } ?? ""))
        }
        if let charge = battery.maxChargeCurrent_mA, let discharge = battery.maxDischargeCurrent_mA {
            lifetime.append("Peak current: charge \(amps(charge)) · discharge \(amps(discharge))")
        }
        if let low = battery.minPackVoltage_mV, let high = battery.maxPackVoltage_mV {
            lifetime.append("Pack voltage: \(volts(low)) – \(volts(high))")
        }
        if let hours = battery.operatingHours {
            lifetime.append("Operating time: \(hours.formatted()) h (\(hours / 24) days)")
        }
        let faults = (battery.permanentFailure ?? 0) + (battery.cellDisconnects ?? 0)
        lifetime.append("Faults: " + (faults == 0 ? "none" : "reported (code \(battery.permanentFailure ?? 0))"))
        if let limited = battery.thermallyLimitedCharging, limited > 0 {
            lifetime.append("Heat-limited charging: \(limited.formatted()) times")
        }
        if !lifetime.isEmpty {
            lines.append("")
            lines.append("Lifetime")
            lines.append(contentsOf: lifetime.map { "   " + $0 })
        }
        return lines.joined(separator: "\n")
    }

    private var adapterStatus: String {
        guard battery.isPluggedIn else { return "Not connected" }
        let parts = [battery.adapterWatts.map { "\($0)W" }, battery.adapterName].compactMap { $0 }
        let state: String = switch battery.state {
        case .charging: "charging"
        case .charged: "fully charged"
        case .pluggedNotCharging: "not charging"
        case .onBattery: ""
        }
        return (["Connected"] + parts).joined(separator: " · ") + (state.isEmpty ? "" : " (\(state))")
    }

    private var maxCapacity: Double { min(max(battery.health ?? 1, 0), 1) }

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
        return battery.charge <= 0.2 ? .orange : Palette.battery   // never red: low battery isn't a fault
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
        .help(tooltip)
    }

    /// Extra details shown when hovering the network card.
    private var tooltip: String {
        let net = monitor.network
        let info = monitor.networkDetails
        guard let interface = net.interfaceName else { return "Offline · no active network interface" }
        var lines: [String] = []

        lines.append("Interface: \(net.interfaceKind) (\(interface))" + (info.macAddress.map { " · MAC \($0)" } ?? ""))
        if let wifi = info.wifi {
            var network = [monitor.wifiName ?? "Wi-Fi"]
            if let bssid = wifi.bssid { network.append("BSSID \(bssid)") }
            lines.append("Network: " + network.joined(separator: " · "))
            if let standard = wifi.standard { lines.append("Standard: \(standard)") }
            if let rssi = wifi.rssi {
                var signal = "Signal: \(rssi) dBm (\(wifi.signalQuality ?? "—"))"
                if let noise = wifi.noise { signal += " · Noise \(noise) dBm · SNR \(rssi - noise) dB" }
                lines.append(signal)
            }
            var channel: [String] = []
            if let number = wifi.channel {
                let extras = [wifi.band, wifi.channelWidth].compactMap { $0 }.joined(separator: ", ")
                channel.append("Channel \(number)" + (extras.isEmpty ? "" : " (\(extras))"))
            }
            if let rate = wifi.transmitRateMbps { channel.append("Tx rate \(Int(rate)) Mbps") }
            if !channel.isEmpty { lines.append(channel.joined(separator: " · ")) }
            let security = [wifi.security.map { "Security: \($0)" }, wifi.countryCode.map { "Country \($0)" }]
                .compactMap { $0 }
            if !security.isEmpty { lines.append(security.joined(separator: " · ")) }
        } else if let speed = info.linkSpeedMbps {
            lines.append("Link speed: \(speed >= 1000 ? "\(speed / 1000) Gbps" : "\(speed) Mbps")")
        }

        if let v4 = net.localIPv4 { lines.append("IPv4: \(v4)" + (info.subnetMask.map { " / \($0)" } ?? "")) }
        if let v6 = net.localIPv6 { lines.append("IPv6: \(v6)") }
        if let router = info.router { lines.append("Router: \(router)") }
        if !info.dnsServers.isEmpty { lines.append("DNS: " + info.dnsServers.joined(separator: ", ")) }
        if !info.searchDomains.isEmpty { lines.append("Search domains: " + info.searchDomains.joined(separator: ", ")) }
        lines.append("Public IP: \(monitor.publicIP ?? "—")")

        lines.append("Traffic since startup: ↓ \(Format.bytes(net.totalDownloaded)) · ↑ \(Format.bytes(net.totalUploaded))")
        let peakDown = monitor.downloadHistory.max() ?? 0, peakUp = monitor.uploadHistory.max() ?? 0
        lines.append("Peak (last minute): ↓ \(Format.rate(peakDown)) · ↑ \(Format.rate(peakUp))")
        lines.append("Low Data Mode: \(net.isConstrained ? "On" : "Off") · "
                     + "Metered: \(net.isExpensive ? "Yes" : "No") · IPv6: \(net.supportsIPv6 ? "Yes" : "No")")
        return lines.joined(separator: "\n")
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
