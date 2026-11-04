import Foundation

/// User preferences, stored in UserDefaults. Settings views bind to these keys with `@AppStorage`;
/// everything else reads the current value here, so changes apply straight away.
enum AppSettings {
    enum Key {
        static let animateIcon = "animateIcon"
        static let showPercentInMenuBar = "showPercentInMenuBar"
        static let refreshInterval = "refreshInterval"
        static let fetchPublicIP = "fetchPublicIP"
        static let temperatureUnit = "temperatureUnit"
        static func showsSection(_ kind: DetailKind) -> String { "showSection.\(kind)" }
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
           let version = plist["CFBundleShortVersionString"] as? String {
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
