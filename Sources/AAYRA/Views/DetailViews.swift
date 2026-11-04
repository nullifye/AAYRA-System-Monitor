import SwiftUI

// MARK: - Building blocks

/// Which card's detail panel is open.
enum DetailKind: Hashable { case cpu, storage, memory, battery, network }

/// Side panel shown next to the main panel when a card is clicked: a header, then grouped
/// sections in two equal columns (one column would outgrow a laptop screen).
struct DetailPanel<Leading: View, Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                IconBadge(symbol: symbol, color: tint, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) { leading() }
                    .frame(maxWidth: .infinity)
                VStack(spacing: 14) { trailing() }
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: Metrics.detailWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small uppercase title above a rounded group of rows separated by hairlines.
struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.semibold))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().opacity(0.5) }
                        row.padding(.vertical, 5)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(radius: 14)
        }
    }
}

/// Label on the left, value on the right. Values can be selected and copied.
struct DetailRow: View {
    let label: String
    let value: String
    var dot: Color?
    #if DEBUG
    /// Shown instead of `value` in screenshots, for personal identifiers (serials, addresses).
    var placeholder: String?
    #endif
    #if DEBUG
    @Environment(\.isSnapshot) private var isSnapshot
    #else
    private let isSnapshot = false   // screenshots are a debug-only feature
    #endif

    init(_ label: String, _ value: String, dot: Color? = nil, placeholder: String? = nil) {
        self.label = label
        self.value = value
        self.dot = dot
        #if DEBUG
        self.placeholder = placeholder
        #endif
    }

    private var shownValue: String {
        #if DEBUG
        if isSnapshot, let placeholder { return placeholder }
        #endif
        return value
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(shownValue)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .textSelection(.enabled)
            }
        }
        .font(.body)
    }
}

/// A process name and value with a thin bar showing its share.
struct ProcessRow: View {
    let name: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            UsageBar(fraction: max(fraction, 0.01), color: tint, height: 4)
        }
        .font(.body)
    }
}

/// Placeholder row for lists that have no data yet.
private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text).font(.body).foregroundStyle(.tertiary)
    }
}

private func pct(_ value: Double) -> String { Format.percent(value) }
private func count<T: BinaryInteger>(_ n: T) -> String { Int64(clamping: n).formatted(.number.notation(.compactName)) }
private func volts(_ mV: Int) -> String { String(format: "%.2f V", Double(mV) / 1000) }
private func amps(_ mA: Int) -> String { String(format: "%.2f A", Double(abs(mA)) / 1000) }
private func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

// MARK: - CPU

struct CPUDetail: View {
    let monitor: SystemMonitor

    var body: some View {
        let cpu = monitor.cpu
        DetailPanel(symbol: "cpu", tint: Palette.cpu, title: "CPU", subtitle: subtitle) {
            DetailSection("Usage") {
                Sparkline(values: monitor.cpuHistory, color: Palette.cpu, height: 34)
                    .padding(.vertical, 2)
                DetailRow("Total", pct(cpu.total))
                DetailRow("User", pct(cpu.user), dot: Palette.cpu)
                DetailRow("System", pct(cpu.system), dot: Palette.cpuSystem)
                DetailRow("Idle", pct(max(0, 1 - cpu.total)))
            }
            DetailSection("Cores") {
                if let groups {
                    CoreCluster(title: "Performance", loads: groups.p, tint: Palette.cpu)
                    CoreCluster(title: "Efficiency", loads: groups.e, tint: Palette.cpuEfficiency)
                } else {
                    CoreCluster(title: "All cores", loads: monitor.cpu.perCore, tint: Palette.cpu)
                }
            }
            topProcesses
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
        }
    }

    private var topProcesses: some View {
        DetailSection("Top Processes") {
            if monitor.topCPUProcesses.isEmpty {
                EmptyRow(text: "Measuring…")
            } else {
                ForEach(monitor.topCPUProcesses, id: \.name) { process in
                    ProcessRow(name: process.name, value: String(format: "%.1f%%", process.percent),
                               fraction: process.percent / 100, tint: Palette.cpu)
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
    private var groups: (p: [Double], e: [Double])? {
        let clusters = ChipInfo.coreClusters, loads = monitor.cpu.perCore
        guard clusters.count == loads.count, !clusters.isEmpty else { return nil }
        let pairs = zip(clusters, loads)
        return (pairs.filter { $0.0 == "P" }.map(\.1), pairs.filter { $0.0 == "E" }.map(\.1))
    }

}

/// One CPU cluster: name, core count and average on top, then a labelled bar per core.
private struct CoreCluster: View {
    let title: String
    let loads: [Double]
    let tint: Color

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
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(loads.enumerated()), id: \.offset) { index, load in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(color(for: load).gradient)
                                .frame(height: max(3, 34 * min(load, 1)))
                        }
                        .frame(height: 34)
                        Text("\(Int((load * 100).rounded()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 40)
                    .accessibilityElement()
                    .accessibilityLabel("Core \(index + 1)")
                    .accessibilityValue(Format.percent(load))
                }
            }
            .animation(.smooth(duration: 0.4), value: loads)
        }
        .padding(.vertical, 3)
    }

    private var average: String {
        loads.isEmpty ? "—" : Format.percent(loads.reduce(0, +) / Double(loads.count))
    }

    private func color(for load: Double) -> Color {
        load > 0.9 ? .red : load > 0.7 ? .orange : tint
    }
}

// MARK: - Storage

struct StorageDetail: View {
    let disk: DiskStats
    let ssd: SSDHealth?

    var body: some View {
        DetailPanel(symbol: "internaldrive.fill", tint: Palette.storage, title: "Storage", subtitle: subtitle) {
            DetailSection("Space") {
                StackedBar(segments: [
                    .init(value: share(disk.used), color: Palette.storage),
                    .init(value: share(disk.purgeable), color: Palette.storagePurgeable),
                ], height: 8)
                .padding(.vertical, 3)
                DetailRow("Used", Format.diskBytes(disk.used), dot: Palette.storage)
                DetailRow("Purgeable", Format.diskBytes(disk.purgeable), dot: Palette.storagePurgeable)
                DetailRow("Free", Format.diskBytes(disk.free))
                DetailRow("Available", Format.diskBytes(disk.available))
                DetailRow("Total", Format.diskBytes(disk.total))
            }
            DetailSection("Volume") {
                DetailRow("Name", disk.volumeName)
                if let format = disk.fileSystem { DetailRow("Format", format) }
                if let encrypted = disk.isEncrypted { DetailRow("FileVault", onOff(encrypted)) }
            }
            if let ssd {
                DetailSection("Lifetime I/O") {
                    DetailRow("Written", Format.diskBytes(Int64(clamping: ssd.bytesWritten)))
                    DetailRow("Read", Format.diskBytes(Int64(clamping: ssd.bytesRead)))
                }
            }
        } trailing: {
            if let ssd {
                let info = ssd.info
                DetailSection("Drive") {
                    if let model = info.model { DetailRow("Model", model) }
                    if let capacity = info.capacityBytes { DetailRow("Capacity", Format.diskBytes(capacity)) }
                    if let interconnect = info.interconnect { DetailRow("Interface", interconnect) }
                    if let bsd = info.bsdName { DetailRow("Device", bsd) }
                    if let serial = info.serial { DetailRow("Serial", serial, placeholder: "0123456789ABCDEF") }
                    if let firmware = info.firmware { DetailRow("Firmware", firmware) }
                }
                DetailSection("Health") {
                    DetailRow("Health", pct(ssd.health), dot: ssd.healthColor)
                    DetailRow("Condition", ssd.condition)
                    DetailRow("Spare", "\(ssd.availableSpare)% (min \(ssd.availableSpareThreshold)%)")
                    if let t = ssd.temperatureC { DetailRow("Temperature", Format.temperature(celsius: t)) }
                    DetailRow("Power-on", "\(ssd.powerOnHours.formatted()) h (\(Int((Double(ssd.powerOnHours) / 24).rounded())) days)")
                    DetailRow("Power cycles", ssd.powerCycles.formatted())
                    DetailRow("Unsafe shutdowns", ssd.unsafeShutdowns.formatted())
                    DetailRow("Media errors", ssd.mediaErrors.formatted())
                }
            } else {
                DetailSection("Drive") { EmptyRow(text: "SMART data unavailable") }
            }
        }
    }

    private var subtitle: String {
        "\(Format.diskBytes(disk.available)) available of \(Format.diskBytes(disk.total))"
    }

    private func share(_ bytes: Int64) -> Double {
        disk.total > 0 ? Double(bytes) / Double(disk.total) : 0
    }
}

// MARK: - Memory

struct MemoryDetail: View {
    let memory: MemoryStats
    let topProcesses: [ProcessMemory]

    var body: some View {
        DetailPanel(symbol: "memorychip", tint: Palette.memory, title: "Memory", subtitle: subtitle) {
            DetailSection("Usage") {
                StackedBar(segments: [
                    .init(value: share(memory.app), color: Palette.memory),
                    .init(value: share(memory.wired), color: Palette.memoryWired),
                    .init(value: share(memory.compressed), color: Palette.memoryCompressed),
                    .init(value: share(memory.cached), color: Palette.memoryCached),
                ], height: 8)
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
                DetailRow("Swap used", memory.swapTotal == 0 ? "None"
                          : "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))")
                DetailRow("Swap-ins · outs", "\(count(memory.swapIns)) · \(count(memory.swapOuts))")
            }
        } trailing: {
            DetailSection("Activity") {
                DetailRow("Compressions", count(memory.compressions))
                DetailRow("Decompressions", count(memory.decompressions))
                DetailRow("Page-ins", count(memory.pageIns))
                DetailRow("Page-outs", count(memory.pageOuts))
            }
            DetailSection("Top Processes") {
                if topProcesses.isEmpty {
                    EmptyRow(text: "Measuring…")
                } else {
                    ForEach(topProcesses, id: \.name) { process in
                        ProcessRow(name: process.name, value: Format.bytes(process.footprint),
                                   fraction: share(process.footprint), tint: Palette.memory)
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

// MARK: - Battery

struct BatteryDetail: View {
    let battery: BatteryStats
    let lowPowerMode: Bool

    var body: some View {
        DetailPanel(symbol: battery.symbol, tint: battery.tint, title: "Battery", subtitle: subtitle) {
            chargeSection
            healthSection
            packSection
        } trailing: {
            powerSection
            lifetimeSection
        }
    }

    private var subtitle: String {
        "\(pct(battery.charge)) · \(battery.stateText)"
    }

    private var chargeSection: some View {
        DetailSection("Charge") {
            StackedBar(segments: [
                .init(value: battery.charge * battery.maxCapacity, color: battery.tint),
                .init(value: (1 - battery.charge) * battery.maxCapacity, color: .clear),
                .init(value: 1 - battery.maxCapacity, color: Palette.batteryWorn),
            ], height: 8)
            .padding(.vertical, 3)
            DetailRow("Charge", pct(battery.charge), dot: battery.tint)
            DetailRow("State", battery.stateText)
            if let t = battery.temperatureC { DetailRow("Temperature", Format.temperature(celsius: t)) }
            if let low = battery.dailyMinSoc, let high = battery.dailyMaxSoc {
                DetailRow("Today's range", "\(low)–\(high)%")
            }
        }
    }

    private var healthSection: some View {
        DetailSection("Health") {
            DetailRow("Max capacity", battery.health.map { pct($0) } ?? "—", dot: battery.tint)
            DetailRow("Worn", pct(1 - battery.maxCapacity), dot: Palette.batteryWorn)
            DetailRow("Condition", battery.condition ?? "—", dot: battery.conditionColor)
            DetailRow("Cycles", battery.cycleText)
            if let full = battery.fullChargeCapacity_mAh {
                DetailRow("Full charge", "\(full)" + (battery.designCapacity_mAh.map { " / \($0)" } ?? "") + " mAh")
            }
            if let remaining = battery.remaining_mAh, let max = battery.rawMax_mAh {
                DetailRow("Remaining", "\(remaining) / \(max) mAh")
            }
        }
    }

    private var packSection: some View {
        DetailSection("Pack") {
            if let date = battery.manufactureDate {
                let when = date.formatted(.dateTime.day().month(.abbreviated).year())
                DetailRow("Manufactured", battery.manufactureDateIsEstimate ? "≈ \(when)" : when)
                DetailRow("Age", (battery.manufactureDateIsEstimate ? "≈ " : "") + Format.age(since: date))
            }
            DetailRow("Assembled by", battery.packManufacturer ?? "Unknown")
            DetailRow("Cells by", battery.manufacturer ?? "Unknown")
            if let serial = battery.serial { DetailRow("Serial", serial, placeholder: "F8Y0000000000000A") }
        }
    }

    private var powerSection: some View {
        DetailSection("Power") {
            DetailRow("Battery", batteryFlow)
            if let load = battery.systemLoadWatts { DetailRow("Mac drawing", String(format: "%.1f W", load)) }
            if let mV = battery.voltage_mV { DetailRow("Voltage", volts(mV)) }
            if let mA = battery.current_mA { DetailRow("Current", "\(mA) mA") }
            if !battery.cellVoltages_mV.isEmpty {
                let cells = battery.cellVoltages_mV
                DetailRow("Cells", cells.map { String(format: "%.3f", Double($0) / 1000) }.joined(separator: " / ") + " V")
                DetailRow("Cell spread", "\((cells.max() ?? 0) - (cells.min() ?? 0)) mV")
            }
            DetailRow("Adapter", battery.adapterStatus)
            if let input = battery.adapterInputWatts { DetailRow("Adapter input", String(format: "%.1f W", input)) }
            DetailRow("Low Power Mode", onOff(lowPowerMode))
        }
    }

    private var lifetimeSection: some View {
        DetailSection("Lifetime") {
            if let low = battery.lifetimeMinTempC, let high = battery.lifetimeMaxTempC {
                DetailRow("Temperature", "\(Format.temperature(celsius: Double(low))) – \(Format.temperature(celsius: Double(high)))")
            }
            if let avg = battery.lifetimeAvgTempC { DetailRow("Average temp", Format.temperature(celsius: avg)) }
            if let charge = battery.maxChargeCurrent_mA { DetailRow("Peak charge", amps(charge)) }
            if let discharge = battery.maxDischargeCurrent_mA { DetailRow("Peak discharge", amps(discharge)) }
            if let low = battery.minPackVoltage_mV, let high = battery.maxPackVoltage_mV {
                DetailRow("Pack voltage", "\(volts(low)) – \(volts(high))")
            }
            if let hours = battery.operatingHours {
                DetailRow("Operating time", "\(hours.formatted()) h (\(hours / 24) d)")
            }
            let faults = (battery.permanentFailure ?? 0) + (battery.cellDisconnects ?? 0)
            DetailRow("Faults", faults == 0 ? "None" : "Code \(battery.permanentFailure ?? 0)")
            if let limited = battery.thermallyLimitedCharging, limited > 0 {
                DetailRow("Heat-limited charging", "\(limited.formatted())×")
            }
        }
    }

    private var batteryFlow: String {
        guard let watts = battery.powerWatts, abs(watts) >= 0.05 else { return "Idle (0 W)" }
        let rate = String(format: "%.1f W", abs(watts))
        return watts < 0 ? "Discharging \(rate)" : "Charging \(rate)"
    }
}

// MARK: - Network

struct NetworkDetail: View {
    let monitor: SystemMonitor

    var body: some View {
        let net = monitor.network
        let info = monitor.networkDetails
        DetailPanel(symbol: net.symbol, tint: net.isConnected ? Palette.network : .gray,
                    title: "Network", subtitle: subtitle) {
            DetailSection("Traffic") {
                DualSparkline(download: monitor.downloadHistory, upload: monitor.uploadHistory, height: 34)
                    .padding(.vertical, 2)
                DetailRow("Download", Format.rate(net.downloadBytesPerSec), dot: Palette.download)
                DetailRow("Upload", Format.rate(net.uploadBytesPerSec), dot: Palette.upload)
                DetailRow("Peak (last min)", "↓ \(Format.rate(monitor.downloadHistory.max() ?? 0)) · "
                          + "↑ \(Format.rate(monitor.uploadHistory.max() ?? 0))")
                DetailRow("Since boot", "↓ \(Format.bytes(net.totalDownloaded)) · ↑ \(Format.bytes(net.totalUploaded))")
            }
            if let interface = net.interfaceName {
                DetailSection("Connection") {
                    DetailRow("Interface", "\(net.interfaceKind) (\(interface))")
                    if let mac = info.macAddress { DetailRow("MAC address", mac, placeholder: "a1:b2:c3:d4:e5:f6") }
                    if info.wifi == nil, let speed = info.linkSpeedMbps {
                        DetailRow("Link speed", speed >= 1000 ? "\(speed / 1000) Gbps" : "\(speed) Mbps")
                    }
                    DetailRow("Low Data Mode", onOff(net.isConstrained))
                    DetailRow("Metered", net.isExpensive ? "Yes" : "No")
                    DetailRow("IPv6", net.supportsIPv6 ? "Supported" : "Not available")
                }
            }
        } trailing: {
            if net.isConnected {
                if let wifi = info.wifi {
                    DetailSection("Wi-Fi") {
                        DetailRow("Network", monitor.wifiName ?? "—", placeholder: "Home Wi-Fi")
                        if let bssid = wifi.bssid { DetailRow("BSSID", bssid, placeholder: "0a:1b:2c:3d:4e:5f") }
                        if let standard = wifi.standard { DetailRow("Standard", standard) }
                        if let rssi = wifi.rssi {
                            DetailRow("Signal", "\(rssi) dBm" + (wifi.signalQuality.map { " (\($0))" } ?? ""),
                                      dot: signalColor(rssi))
                            if let noise = wifi.noise { DetailRow("Noise · SNR", "\(noise) dBm · \(rssi - noise) dB") }
                        }
                        if let channel = wifi.channel {
                            let extras = [wifi.band, wifi.channelWidth].compactMap { $0 }.joined(separator: ", ")
                            DetailRow("Channel", "\(channel)" + (extras.isEmpty ? "" : " (\(extras))"))
                        }
                        if let rate = wifi.transmitRateMbps { DetailRow("Tx rate", "\(Int(rate)) Mbps") }
                        if let security = wifi.security { DetailRow("Security", security) }
                        if let country = wifi.countryCode { DetailRow("Country", country) }
                    }
                }
                DetailSection("Addresses") {
                    if let v4 = net.localIPv4 { DetailRow("IPv4", v4, placeholder: "192.168.1.20") }
                    if let mask = info.subnetMask { DetailRow("Subnet mask", mask) }
                    if let v6 = net.localIPv6 { DetailRow("IPv6", v6, placeholder: "2001:db8::20") }
                    if let router = info.router { DetailRow("Router", router, placeholder: "192.168.1.1") }
                    ForEach(Array(info.dnsServers.enumerated()), id: \.offset) { index, server in
                        DetailRow(index == 0 ? "DNS" : "", server, placeholder: index == 0 ? "1.1.1.1" : "1.0.0.1")
                    }
                    if !info.searchDomains.isEmpty { DetailRow("Search domains", info.searchDomains.joined(separator: ", "), placeholder: "home") }
                    DetailRow("Public IP", monitor.publicIP ?? "—", placeholder: "203.0.113.42")
                }
            } else {
                DetailSection("Status") { EmptyRow(text: "No active network interface") }
            }
        }
    }

    private var subtitle: String {
        let net = monitor.network
        guard net.isConnected else { return "Offline · no active network interface" }
        if net.interfaceKind == "Wi-Fi", let name = monitor.wifiName { return "Wi-Fi · \(name)" }
        return net.interfaceKind
    }

    private func signalColor(_ rssi: Int) -> Color {
        rssi >= -67 ? .green : rssi >= -75 ? .yellow : .orange
    }
}

// MARK: - Shared helpers (used by the cards and the detail panels)

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

extension SSDHealth {
    var healthColor: Color {
        if condition == "Check Drive" { return .red }
        return health >= 0.8 ? .green : health >= 0.5 ? .orange : .red
    }
}

extension NetworkStats {
    var symbol: String {
        switch interfaceKind {
        case "Wi-Fi": "wifi"
        case "Ethernet": "cable.connector"
        case "Offline": "wifi.slash"
        default: "network"
        }
    }
}

extension BatteryStats {
    var maxCapacity: Double { min(max(health ?? 1, 0), 1) }

    var symbol: String {
        if state == .charging || state == .charged { return "battery.100percent.bolt" }
        switch charge {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Never red: a low battery isn't a fault.
    var tint: Color {
        if isPluggedIn { return Palette.battery }
        return charge <= 0.2 ? .orange : Palette.battery
    }

    /// State and time in one short phrase, e.g. "6h 35m left" or "Charging · 1h 10m".
    var stateText: String {
        switch state {
        case .onBattery: minutesToEmpty.map { "\(Format.minutes($0)) left" } ?? "Calculating…"
        case .charging: "Charging" + (minutesToFull.map { " · \(Format.minutes($0))" } ?? "")
        case .charged: "Charged"
        case .pluggedNotCharging: "Not Charging"
        }
    }

    var cycleText: String {
        guard let cycles = cycleCount else { return "—" }
        return designCycles.map { "\(cycles) / \($0)" } ?? "\(cycles)"
    }

    var capacityText: String {
        guard let now = currentCapacity_mAh, let design = designCapacity_mAh else { return "—" }
        return "\(now) / \(design) mAh"
    }

    var conditionColor: Color {
        switch condition?.lowercased() {
        case "good", "normal": .green
        case nil: .secondary
        default: .orange   // "Fair", "Service Recommended", …
        }
    }

    var adapterStatus: String {
        guard isPluggedIn else { return "Not connected" }
        let parts = [adapterWatts.map { "\($0)W" }, adapterName].compactMap { $0 }
        let detail: String = switch state {
        case .charging: "charging"
        case .charged: "full"
        case .pluggedNotCharging: "not charging"
        case .onBattery: ""
        }
        let text = parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
        return text + (detail.isEmpty ? "" : " (\(detail))")
    }
}
