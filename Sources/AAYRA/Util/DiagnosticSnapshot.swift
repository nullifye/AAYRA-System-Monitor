import Foundation

/// A point-in-time copy. Formatting never queries the machine again or makes a network request.
struct DiagnosticSnapshot {
    struct Options: Equatable {
        var includeIPAddresses = false
        var includeSerialNumbers = false
        var includeProcessNames = false
    }

    var capturedAt: Date
    var version: String
    var macModel: String
    var chip: String
    var macOS: String
    var cpu: CPUStats
    var thermalState: ProcessInfo.ThermalState
    var memory: MemoryStats
    var disk: DiskStats
    var diskIO: DiskIO
    var mountedVolumeCount: Int
    var ssd: SSDHealth?
    var battery: BatteryStats?
    var batteryDrainCause: BatteryDrainInsight.Cause?
    var gpu: GPUStats?
    var network: NetworkStats
    var publicIP: String?
    var topCPUProcesses: [ProcessCPU]
    var topMemoryProcesses: [ProcessMemory]

    init(
        capturedAt: Date, version: String, macModel: String, chip: String, macOS: String,
        cpu: CPUStats, thermalState: ProcessInfo.ThermalState, memory: MemoryStats,
        disk: DiskStats, diskIO: DiskIO, mountedVolumeCount: Int, ssd: SSDHealth?,
        battery: BatteryStats?, batteryDrainCause: BatteryDrainInsight.Cause?, gpu: GPUStats?,
        network: NetworkStats, publicIP: String?, topCPUProcesses: [ProcessCPU],
        topMemoryProcesses: [ProcessMemory]
    ) {
        self.capturedAt = capturedAt
        self.version = version
        self.macModel = macModel
        self.chip = chip
        self.macOS = macOS
        self.cpu = cpu
        self.thermalState = thermalState
        self.memory = memory
        self.disk = disk
        self.diskIO = diskIO
        self.mountedVolumeCount = mountedVolumeCount
        self.ssd = ssd
        self.battery = battery
        self.batteryDrainCause = batteryDrainCause
        self.gpu = gpu
        self.network = network
        self.publicIP = publicIP
        self.topCPUProcesses = topCPUProcesses
        self.topMemoryProcesses = topMemoryProcesses
    }

    @MainActor
    init(monitor: SystemMonitor) {
        self.init(
            capturedAt: Date(), version: AppInfo.version, macModel: MachineInfo.productName,
            chip: MachineInfo.chip, macOS: MachineInfo.osVersion, cpu: monitor.cpu,
            thermalState: monitor.thermalState, memory: monitor.memory, disk: monitor.disk,
            diskIO: monitor.diskIO, mountedVolumeCount: monitor.volumes.count, ssd: monitor.ssd,
            battery: monitor.battery, batteryDrainCause: monitor.batteryDrainInsight.cause,
            gpu: monitor.gpu, network: monitor.network, publicIP: monitor.publicIP,
            topCPUProcesses: monitor.topCPUProcesses, topMemoryProcesses: monitor.topProcesses)
    }

    func text(options: Options = Options()) -> String {
        var lines = [
            "AAYRA Diagnostic Snapshot",
            "Captured: \(capturedAt.ISO8601Format())",
            "AAYRA version: \(Self.safe(version))",
            "",
            "System",
            "  Model: \(Self.safe(macModel))",
            "  Chip: \(Self.safe(chip))",
            "  OS: \(Self.safe(macOS))",
            "  Thermal state: \(thermalDescription)",
            "",
            "CPU",
            "  Usage: \(Format.percent(cpu.total)) (user \(Format.percent(cpu.user)), system \(Format.percent(cpu.system)))",
            "",
            "Memory",
            "  Used: \(Format.bytes(memory.used)) / \(Format.bytes(memory.total))",
            "  Pressure: \(memory.pressure)",
            "  Swap used: \(Format.bytes(memory.swapUsed))",
            "",
            "Storage",
        ]
        if disk.total > 0 {
            lines.append("  Available: \(Format.diskBytes(disk.available)) / \(Format.diskBytes(disk.total))")
            lines.append("  Free (not purgeable): \(Format.diskBytes(disk.free))")
        } else {
            lines.append("  Startup disk: Unavailable")
        }
        lines.append("  Activity: read \(Format.rate(diskIO.readBytesPerSec)), write \(Format.rate(diskIO.writeBytesPerSec))")
        lines.append("  Other mounted volumes: \(mountedVolumeCount) (names omitted)")
        if let ssd {
            lines.append("  SSD health: \(Format.percent(ssd.health)); condition: \(Self.safe(ssd.condition))")
            lines.append("  SMART: critical warning \(Self.yesNo(ssd.hasCriticalWarning)), media errors \(ssd.mediaErrors)")
            lines.append("  SSD spare: \(ssd.availableSpare)% (threshold \(ssd.availableSpareThreshold)%)")
            if let temp = ssd.temperatureC { lines.append("  SSD temperature: \(Self.celsius(temp))") }
        } else {
            lines.append("  SSD SMART: Unavailable")
        }

        lines.append(contentsOf: ["", "Battery"])
        if let battery {
            lines.append("  Charge: \(Format.percent(battery.charge)); state: \(Self.batteryState(battery.state))")
            if let health = battery.health { lines.append("  Maximum capacity: \(Format.percent(health))") }
            if let cycles = battery.cycleCount { lines.append("  Cycles: \(cycles)") }
            if let temp = battery.temperatureC { lines.append("  Temperature: \(Self.celsius(temp))") }
            if let watts = battery.powerWatts { lines.append("  Power flow: \(Self.watts(watts)) (positive = charging)") }
            if let rated = battery.adapterWatts { lines.append("  Adapter rating: \(rated) W") }
            if let load = battery.systemLoadWatts { lines.append("  Mac power use: \(Self.watts(load))") }
            if let cause = batteryDrainCause { lines.append("  Draining on AC: \(cause.title)") }
        } else {
            lines.append("  No battery data")
        }

        lines.append(contentsOf: ["", "GPU"])
        if let gpu {
            lines.append("  Utilization: \(Format.percent(gpu.device)); recoveries: \(gpu.recoveries)")
            lines.append("  Memory in use: \(Format.bytes(gpu.memoryInUse))")
        } else {
            lines.append("  Not sampled")
        }

        lines.append(contentsOf: ["", "Network"])
        lines.append("  Connection: \(Self.safe(network.interfaceKind))")
        lines.append("  VPN tunnel detected: \(Self.yesNo(network.isVPNConnected))")
        lines.append("  Traffic: down \(Format.rate(network.downloadBytesPerSec)), up \(Format.rate(network.uploadBytesPerSec))")
        if options.includeIPAddresses {
            lines.append("  Local IPv4: \(Self.safe(network.localIPv4 ?? "Unavailable"))")
            lines.append("  Local IPv6: \(Self.safe(network.localIPv6 ?? "Unavailable"))")
            lines.append("  VPN IPv4: \(Self.safe(network.vpnAddress ?? "Unavailable"))")
            lines.append("  Public IP: \(Self.safe(publicIP ?? "Unavailable (not fetched)"))")
        } else {
            lines.append("  IP addresses: Omitted (not selected)")
        }

        lines.append(contentsOf: ["", "Device identifiers"])
        if options.includeSerialNumbers {
            lines.append("  Battery serial: \(Self.safe(battery?.serial ?? "Unavailable"))")
            lines.append("  SSD serial: \(Self.safe(ssd?.info.serial ?? "Unavailable"))")
        } else {
            lines.append("  Serial numbers: Omitted (not selected)")
        }

        lines.append(contentsOf: ["", "Processes"])
        if options.includeProcessNames {
            lines.append("  Top CPU apps:")
            lines.append(
                contentsOf: topCPUProcesses.isEmpty
                    ? ["    No recent process sample"]
                    : topCPUProcesses.map { "    \(Self.processName($0.name)): \(String(format: "%.1f%%", $0.percent))" })
            lines.append("  Top memory apps:")
            lines.append(
                contentsOf: topMemoryProcesses.isEmpty
                    ? ["    No recent process sample"]
                    : topMemoryProcesses.map { "    \(Self.processName($0.name)): \(Format.bytes($0.footprint))" })
        } else {
            lines.append("  Process names: Omitted (not selected)")
        }
        lines.append(contentsOf: ["", "Wi-Fi names, MAC addresses, volume names and file paths are never included."])
        return lines.joined(separator: "\n") + "\n"
    }

    private var thermalDescription: String {
        switch thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private static func batteryState(_ state: BatteryStats.State) -> String {
        switch state {
        case .charging: "Charging"
        case .charged: "Charged"
        case .onBattery: "On battery"
        case .pluggedNotCharging: "Plugged in, not charging"
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
    private static func watts(_ value: Double) -> String { String(format: "%.1f W", value) }
    private static func celsius(_ value: Double) -> String { String(format: "%.1f °C", value) }

    /// Prevent names supplied by the system or a process from injecting extra report lines.
    private static func safe(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
    }

    /// A process display name may itself be an executable path. Never export its directories.
    private static func processName(_ value: String) -> String {
        safe(
            value.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).last.map(
                String.init)
                ?? "Unknown")
    }
}
