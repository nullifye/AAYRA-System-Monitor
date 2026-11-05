import Foundation
import UserNotifications

extension Notification.Name {
    /// Asks the menu bar controller to open the panel (e.g. after clicking an alert).
    static let aayraShowPanel = Notification.Name("AAYRAShowPanel")
}

/// Turns the alert rules' decisions into macOS notifications.
///
/// Alerts are off by default. macOS asks for permission to show notifications the first time one
/// is turned on in Settings. Each alert replaces its own previous notification instead of piling up.
@MainActor
@Observable
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()

    /// Whether macOS lets AAYRA show notifications (shown in Settings when they're blocked).
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private var rules = AlertRules()
    private let processes = ProcessSampler()  // to name the app behind high CPU or memory
    /// UserNotifications needs a real app bundle; unbundled debug runs (e.g. `--render`) skip it.
    private let canNotify = Bundle.main.bundleIdentifier != nil

    override private init() {
        super.init()
        guard canNotify else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    /// Called on every monitor tick.
    func check(_ monitor: SystemMonitor) {
        let settings = AlertSettings.current
        let battery = monitor.battery
        let snapshot = AlertSnapshot(
            batteryCharge: battery?.charge,
            onBattery: battery?.state == .onBattery,
            diskAvailable: monitor.disk.total > 0 ? monitor.disk.available : .max,
            memoryPressure: monitor.memory.pressure,
            cpu: monitor.cpu.total)
        for kind in rules.evaluate(snapshot, settings: settings, now: ProcessInfo.processInfo.systemUptime) {
            Task { await send(kind, monitor: monitor, settings: settings) }
        }
    }

    /// Asks for permission when an alert is turned on (macOS shows its prompt only once).
    func requestAuthorization() {
        guard canNotify else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            refreshAuthorization()
        }
    }

    func refreshAuthorization() {
        guard canNotify else { return }
        Task {
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    // MARK: Messages

    private func send(_ kind: AlertKind, monitor: SystemMonitor, settings: AlertSettings) async {
        let (title, body) = await message(for: kind, monitor: monitor, settings: settings)
        guard canNotify else { return }
        // Alerts turned on outside Settings (e.g. imported preferences) still get macOS's permission prompt.
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            refreshAuthorization()
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = kind.rawValue
        // One notification per kind: a new one replaces the previous instead of stacking up.
        let request = UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func message(for kind: AlertKind, monitor: SystemMonitor, settings: AlertSettings) async
        -> (String, String)
    {
        switch kind {
        case .batteryLow:
            let battery = monitor.battery
            let percent = Format.percent(battery?.charge ?? 0)
            let left = battery?.minutesToEmpty.map { "About \(Format.minutes($0)) left. " } ?? ""
            return ("Battery low: \(percent)", left + "Connect a charger soon.")

        case .diskFull:
            let disk = monitor.disk
            return (
                "\(disk.volumeName) is almost full",
                "Only \(Format.diskBytes(disk.available)) available of \(Format.diskBytes(disk.total)). "
                    + "Free up space in System Settings → General → Storage."
            )

        case .memoryPressure:
            let memory = monitor.memory
            let level = memory.pressure == .critical ? "critical" : "high"
            var body = "\(Format.memoryShort(memory.used)) of \(Format.bytes(memory.total)) in use"
            if memory.swapUsed > 0 { body += ", \(Format.memoryShort(memory.swapUsed)) swapped to disk" }
            body += "."
            if let top = processes.sample(top: 1).memory.first {
                body += " Using the most: \(top.name) (\(Format.memoryShort(top.footprint)))."
            }
            return ("Memory pressure is \(level)", body)

        case .cpuBusy:
            // CPU per app needs two readings a moment apart.
            _ = processes.sample(top: 1)
            try? await Task.sleep(for: .seconds(2))
            var body = "Running at \(Format.percent(monitor.cpu.total)) for over \(settings.cpuMinutes) minutes."
            if let top = processes.sample(top: 1).cpu.first {
                body += " Busiest: \(top.name) (\(String(format: "%.0f%%", top.percent)))."
            }
            return ("CPU has been busy for \(settings.cpuMinutes) minutes", body)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show alerts as banners even while AAYRA's own windows are in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking an alert opens the panel.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { NotificationCenter.default.post(name: .aayraShowPanel, object: nil) }
    }
}

extension AlertSettings {
    /// The user's current choices from Settings → Alerts.
    static var current: AlertSettings {
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        func bool(_ key: String) -> Bool { d.bool(forKey: key) }
        typealias K = AppSettings.Key
        return AlertSettings(
            batteryLow: bool(K.alertBatteryLow),
            batteryThreshold: int(K.alertBatteryThreshold, 20),
            diskFull: bool(K.alertDiskFull),
            diskThresholdGB: int(K.alertDiskThresholdGB, 10),
            memoryPressure: bool(K.alertMemoryPressure),
            memoryCriticalOnly: bool(K.alertMemoryCriticalOnly),
            cpuBusy: bool(K.alertCPUBusy),
            cpuMinutes: int(K.alertCPUMinutes, 5))
    }
}
