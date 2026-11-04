import AppKit
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
    private(set) var gpu: GPUStats?
    private(set) var gpuHistory: [Double] = Array(repeating: 0, count: historyLength)
    private(set) var diskIO = DiskIO()
    /// Mounted volumes other than the startup disk (external drives, disk images, network shares).
    private(set) var volumes: [VolumeStats] = []
    /// Shown briefly after an eject fails (e.g. "“Backup” is in use").
    private(set) var volumeMessage: String?
    private(set) var diskReadHistory: [Double] = Array(repeating: 0, count: historyLength)
    private(set) var diskWriteHistory: [Double] = Array(repeating: 0, count: historyLength)

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
    private let diskIOProvider = DiskIOProvider()
    private let wifiProvider = WiFiNameProvider()
    // When each periodic job last ran (system uptime, seconds). Jobs run on elapsed time, not on
    // sample counts, so they keep their schedule whatever the refresh interval is.
    private var lastDetailsRefresh: TimeInterval = 0
    private var lastSlowRefresh: TimeInterval = 0
    private var lastSSDRefresh: TimeInterval = 0
    private var lastHealthRefresh: TimeInterval = 0
    /// Refresh interval the current chart history was sampled at.
    private(set) var historyInterval = AppSettings.refreshInterval

    /// Time span the charts cover: a fixed number of samples × the refresh interval.
    var historySpan: TimeInterval { Double(Self.historyLength) * historyInterval }
    private var publicIPFetchedAt: Date?
    private var publicIPInterface: String?
    private var reportedHealth: BatteryProvider.ReportedHealth?
    private var loop: Task<Void, Never>?

    init() {
        performanceCores = cpuProvider.performanceCores
        efficiencyCores = cpuProvider.efficiencyCores
        _ = cpuProvider.sample()            // prime the tick baseline
        _ = networkProvider.sample()
        _ = diskIOProvider.sample()
        gpu = GPUProvider.sample()
        refreshSlowMetrics()
        refreshSSD()
        lastHealthRefresh = Self.now
        Task { await refreshReportedHealth() }
        wifiProvider.onAuthorizationChange = { [weak self] in self?.refreshWiFiName() }
        // Update the volume list the moment a drive is plugged in, ejected or renamed.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumes = VolumeProvider.sample() }
            }
        }
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

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// True once `period` seconds have passed since `last` (with a little slack for timer jitter).
    private static func isDue(_ last: TimeInterval, every period: TimeInterval, now: TimeInterval) -> Bool {
        now - last >= period - 0.25
    }

    private func tick() {
        let now = Self.now
        let interval = AppSettings.refreshInterval
        if interval != historyInterval {
            // Samples taken at different intervals can't share one time axis, so start the charts afresh.
            historyInterval = interval
            cpuHistory = Array(repeating: 0, count: Self.historyLength)
            downloadHistory = Array(repeating: 0, count: Self.historyLength)
            uploadHistory = Array(repeating: 0, count: Self.historyLength)
            gpuHistory = Array(repeating: 0, count: Self.historyLength)
            diskReadHistory = Array(repeating: 0, count: Self.historyLength)
            diskWriteHistory = Array(repeating: 0, count: Self.historyLength)
        }

        if let sample = cpuProvider.sample() {
            cpu = sample
            push(&cpuHistory, sample.total)
            smoothedCPU += 0.35 * (sample.total - smoothedCPU)
        }
        if let m = MemoryProvider.sample() { memory = m }
        // Only read the GPU while its card is turned on.
        if AppSettings.showsGPU, let g = GPUProvider.sample() {
            gpu = g
            push(&gpuHistory, g.device)
        }
        if isPanelOpen && Self.isDue(lastDetailsRefresh, every: 3, now: now) {
            sampleProcesses()
            refreshNetworkDetails()
        }
        thermalState = ProcessInfo.processInfo.thermalState

        let previousInterface = network.interfaceName
        network = networkProvider.sample()
        push(&downloadHistory, network.downloadBytesPerSec)
        push(&uploadHistory, network.uploadBytesPerSec)
        diskIO = diskIOProvider.sample()
        push(&diskReadHistory, diskIO.readBytesPerSec)
        push(&diskWriteHistory, diskIO.writeBytesPerSec)
        if network.interfaceName != previousInterface {   // network changed
            publicIPFetchedAt = nil
            refreshWiFiName()
        }

        if Self.isDue(lastSlowRefresh, every: 10, now: now) { refreshSlowMetrics() }
        if Self.isDue(lastSSDRefresh, every: 60, now: now) { refreshSSD() }      // SMART changes slowly
        if Self.isDue(lastHealthRefresh, every: 1800, now: now) {                // every 30 min
            lastHealthRefresh = now
            Task { await refreshReportedHealth() }
        }
    }

    private func refreshSSD() {
        lastSSDRefresh = Self.now
        ssd = SSDHealthProvider.sample()
    }

    private func refreshSlowMetrics() {
        lastSlowRefresh = Self.now
        if let d = DiskProvider.sample() { disk = d }
        volumes = VolumeProvider.sample()
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
        refreshSSD()
        if network.interfaceKind == "Wi-Fi" { wifiProvider.requestAccessIfNeeded() }
        refreshPublicIP(force: false)
    }

    private func refreshNetworkDetails() {
        networkDetails = NetworkDetailsProvider.sample(interface: network.interfaceName,
                                                       isWiFi: network.interfaceKind == "Wi-Fi")
    }

    private func sampleProcesses() {
        lastDetailsRefresh = Self.now
        let result = processSampler.sample(top: 5)
        topProcesses = result.memory
        topCPUProcesses = result.cpu
        processCount = processSampler.processCount
    }

    /// Unmounts and ejects a volume (off the main thread, as Finder can take a moment).
    func eject(_ volume: VolumeStats) {
        let url = volume.url, name = volume.name
        Task.detached {
            let failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                failure = nil
            } catch {
                failure = "Couldn't eject “\(name)”. It may be in use."
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.volumes = VolumeProvider.sample()
                self.volumeMessage = failure
            }
            if failure != nil {
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run { [weak self] in
                    if self?.volumeMessage == failure { self?.volumeMessage = nil }
                }
            }
        }
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
