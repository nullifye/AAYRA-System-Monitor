import Foundation
import Observation

/// Collects every metric on a 1-second tick. Expensive sources refresh less often.
@MainActor
@Observable
final class SystemMonitor {
    static let historyLength = 60

    private(set) var cpu = CPUStats()
    private(set) var cpuHistory: [Double] = Array(repeating: 0, count: historyLength)
    /// Exponentially smoothed CPU load (0...1) that drives the menu bar animation.
    private(set) var smoothedCPU: Double = 0

    private(set) var memory = MemoryStats()
    /// Biggest memory users; refreshed only while the panel is open.
    private(set) var topProcesses: [ProcessMemory] = []
    private(set) var topCPUProcesses: [ProcessCPU] = []
    private(set) var processCount = 0
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private let processSampler = ProcessSampler()
    private var isPanelOpen = false
    private(set) var disk = DiskStats()
    private(set) var ssd: SSDHealth?
    private(set) var battery: BatteryStats?
    private(set) var network = NetworkStats()
    private(set) var downloadHistory: [Double] = Array(repeating: 0, count: historyLength)
    private(set) var uploadHistory: [Double] = Array(repeating: 0, count: historyLength)

    private(set) var wifiName: String?
    private(set) var networkDetails = NetworkDetails()
    private(set) var wifiAccess: WiFiNameProvider.Access = .notDetermined
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var publicIP: String?
    private(set) var isFetchingPublicIP = false
    private(set) var bootDate = MachineInfo.bootDate

    let performanceCores: Int
    let efficiencyCores: Int

    private let cpuProvider = CPUProvider()
    private let networkProvider = NetworkProvider()
    private let wifiProvider = WiFiNameProvider()
    private var tickCount = 0
    private var publicIPFetchedAt: Date?
    private var publicIPInterface: String?
    private var reportedHealth: BatteryProvider.ReportedHealth?
    private var loop: Task<Void, Never>?

    init() {
        performanceCores = cpuProvider.performanceCores
        efficiencyCores = cpuProvider.efficiencyCores
        _ = cpuProvider.sample()            // prime the tick baseline
        _ = networkProvider.sample()
        refreshSlowMetrics()
        ssd = SSDHealthProvider.sample()
        Task { await refreshReportedHealth() }
        wifiProvider.onAuthorizationChange = { [weak self] in self?.refreshWiFiName() }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppSettings.refreshInterval))
                self?.tick()
            }
        }
    }

    private func tick() {
        tickCount += 1

        if let sample = cpuProvider.sample() {
            cpu = sample
            push(&cpuHistory, sample.total)
            smoothedCPU += 0.35 * (sample.total - smoothedCPU)
        }
        if let m = MemoryProvider.sample() { memory = m }
        if isPanelOpen && tickCount % 3 == 0 {
            sampleProcesses()
            refreshNetworkDetails()
        }
        thermalState = ProcessInfo.processInfo.thermalState

        let previousInterface = network.interfaceName
        network = networkProvider.sample()
        push(&downloadHistory, network.downloadBytesPerSec)
        push(&uploadHistory, network.uploadBytesPerSec)
        if network.interfaceName != previousInterface {   // network changed
            publicIPFetchedAt = nil
            refreshWiFiName()
        }

        if tickCount % 10 == 0 { refreshSlowMetrics() }
        if tickCount % 60 == 0 { ssd = SSDHealthProvider.sample() }             // SMART changes slowly
        if tickCount % 1800 == 0 { Task { await refreshReportedHealth() } }      // every 30 min
    }

    private func refreshSlowMetrics() {
        if let d = DiskProvider.sample() { disk = d }
        battery = BatteryProvider.sample().map { b in
            var b = b
            b.reportedHealth = reportedHealth?.maximumCapacity
            if let condition = reportedHealth?.condition { b.condition = condition }
            return b
        }
        bootDate = MachineInfo.bootDate
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshWiFiName()
    }

    private func refreshWiFiName() {
        wifiAccess = wifiProvider.access
        wifiName = network.interfaceKind == "Wi-Fi" ? wifiProvider.currentSSID : nil
    }

    /// Asks once for the Location permission macOS requires before it reveals the Wi-Fi name.
    func requestWiFiNameAccess() {
        if wifiProvider.access == .denied {
            WiFiNameProvider.openLocationSettings()
        } else {
            wifiProvider.requestAccessIfNeeded()
        }
    }

    private func refreshReportedHealth() async {
        guard battery != nil, let result = await BatteryProvider.fetchReportedHealth() else { return }
        reportedHealth = result
        refreshSlowMetrics()
    }

    /// Called when the panel opens: refresh slow values right away and fetch the public IP if stale.
    func panelDidOpen() {
        isPanelOpen = true
        sampleProcesses()   // CPU ranking appears on the next sample (needs two readings)
        refreshNetworkDetails()
        refreshSlowMetrics()
        ssd = SSDHealthProvider.sample()
        if network.interfaceKind == "Wi-Fi" { wifiProvider.requestAccessIfNeeded() }
        refreshPublicIP(force: false)
    }

    private func refreshNetworkDetails() {
        networkDetails = NetworkDetailsProvider.sample(interface: network.interfaceName,
                                                       isWiFi: network.interfaceKind == "Wi-Fi")
    }

    private func sampleProcesses() {
        let result = processSampler.sample(top: 5)
        topProcesses = result.memory
        topCPUProcesses = result.cpu
        processCount = processSampler.processCount
    }

    func panelDidClose() {
        isPanelOpen = false
    }

    func refreshPublicIP(force: Bool) {
        guard AppSettings.fetchPublicIP else {
            publicIP = nil
            publicIPFetchedAt = nil
            return
        }
        guard !isFetchingPublicIP, network.isConnected else {
            if !network.isConnected { publicIP = nil }
            return
        }
        if !force, let at = publicIPFetchedAt, Date().timeIntervalSince(at) < 300 { return }
        isFetchingPublicIP = true
        Task {
            let ip = await PublicIPService.fetch()
            publicIP = ip
            publicIPFetchedAt = ip == nil ? nil : Date()
            isFetchingPublicIP = false
        }
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.removeFirst()
        history.append(value)
    }
}
