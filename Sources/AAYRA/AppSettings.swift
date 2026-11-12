import Foundation

/// User preferences, stored in UserDefaults. Settings views bind to these keys with `@AppStorage`;
/// everything else reads the current value here, so changes apply straight away.
enum AppSettings {
    enum Key {
        static let animateIcon = "animateIcon"
        static let showPercentInMenuBar = "showPercentInMenuBar"
        static let showNetworkInMenuBar = "showNetworkInMenuBar"
        static let showAgentUsageInMenuBar = "showAgentUsageInMenuBar"
        static let agentChoices = "agentUsageChoices"
        /// Order of the agent rows and cards, as `AgentTool` raw values.
        static let agentOrder = "agentUsageOrder"
        static let agentMenuBarTools = "agentUsageMenuBarTools"
        /// Off by default: folder names are personal and would show up in screenshots.
        static let agentShowProjects = "agentUsageShowProjects"
        static let shortcut = "panelShortcut"
        static let checkForUpdates = "checkForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let latestKnownVersion = "latestKnownVersion"
        static let latestKnownURL = "latestKnownURL"
        static let refreshInterval = "refreshInterval"
        static let fetchPublicIP = "fetchPublicIP"
        static let temperatureUnit = "temperatureUnit"
        static let alertBatteryLow = "alertBatteryLow"
        static let alertBatteryDrain = "alertBatteryDrain"
        static let alertBatteryHeat = "alertBatteryHeat"
        static let alertSSDHealth = "alertSSDHealth"
        static let alertVPNDisconnect = "alertVPNDisconnect"
        static let alertBatteryThreshold = "alertBatteryThreshold"
        static let alertDiskFull = "alertDiskFull"
        static let alertDiskThresholdGB = "alertDiskThresholdGB"
        static let alertMemoryPressure = "alertMemoryPressure"
        static let alertMemoryCriticalOnly = "alertMemoryCriticalOnly"
        static let alertCPUBusy = "alertCPUBusy"
        static let alertCPUMinutes = "alertCPUMinutes"
        static func showsSection(_ kind: DetailKind) -> String { "showSection.\(kind)" }
    }

    /// Keyboard shortcut that opens and closes the panel from any app.
    enum Shortcut: String, CaseIterable {
        case optionCommandM, controlOptionM, controlOptionCommandM, off

        var title: String {
            switch self {
            case .optionCommandM: "⌥⌘M"
            case .controlOptionM: "⌃⌥M"
            case .controlOptionCommandM: "⌃⌥⌘M"
            case .off: "Off"
            }
        }
    }

    enum TemperatureUnit: String, CaseIterable {
        case system, celsius, fahrenheit
    }

    private static var defaults: UserDefaults { .standard }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    static var animateIcon: Bool { bool(Key.animateIcon, default: true) }
    static var showPercentInMenuBar: Bool { bool(Key.showPercentInMenuBar, default: false) }
    static var showNetworkInMenuBar: Bool { bool(Key.showNetworkInMenuBar, default: false) }
    static var showAgentUsageInMenuBar: Bool { bool(Key.showAgentUsageInMenuBar, default: false) }
    /// Agents ticked or unticked in the Agent Usage panel, keyed by `AgentTool` id. Missing ids use the default.
    static var agentChoices: [String: Bool] {
        get { defaults.dictionary(forKey: Key.agentChoices) as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: Key.agentChoices) }
    }
    /// Order chosen by dragging rows in Show Agents. Empty means the built-in order.
    static var agentOrder: [String] {
        get { defaults.stringArray(forKey: Key.agentOrder) ?? [] }
        set { defaults.set(newValue, forKey: Key.agentOrder) }
    }
    static var agentMenuBarTools: [AgentTool] {
        get { AgentMenuBarSelection.validated(defaults.stringArray(forKey: Key.agentMenuBarTools) ?? []) }
        set {
            defaults.set(AgentMenuBarSelection.validated(newValue.map(\.rawValue)).map(\.rawValue), forKey: Key.agentMenuBarTools)
        }
    }
    /// Automatic update checks are off unless turned on in Settings → Updates.
    static var checkForUpdates: Bool { bool(Key.checkForUpdates, default: false) }
    /// The GPU card is off unless turned on in Settings → Sections.
    static var showsGPU: Bool { bool(Key.showsSection(.gpu), default: false) }
    static var shortcut: Shortcut {
        Shortcut(rawValue: defaults.string(forKey: Key.shortcut) ?? "") ?? .optionCommandM
    }
    static var fetchPublicIP: Bool { bool(Key.fetchPublicIP, default: true) }

    /// Seconds between readings: 1, 2 or 5.
    static var refreshInterval: Double {
        let value = defaults.double(forKey: Key.refreshInterval)
        return value > 0 ? value : 1
    }

    static var temperatureUnit: TemperatureUnit {
        TemperatureUnit(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .system
    }
}

enum AppInfo {
    static let author = "RFHN"
    static let repositoryURL = URL(string: "https://github.com/nullifye/AAYRA-System-Monitor")!
    static let authorTelegramURL = URL(string: "https://t.me/mohdrafhan")!

    /// Marketing version, e.g. "1.2".
    static let version: String = {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        #if DEBUG
            // Unbundled debug runs (e.g. `--render`) read it from the source plist.
            if let plist = NSDictionary(contentsOfFile: "Resources/Info.plist"),
                let version = plist["CFBundleShortVersionString"] as? String
            {
                return version
            }
        #endif
        return ""
    }()
}

extension Notification.Name {
    /// Asks the menu bar controller to close the floating panel (e.g. when Settings opens).
    static let aayraClosePanel = Notification.Name("AAYRAClosePanel")
}
