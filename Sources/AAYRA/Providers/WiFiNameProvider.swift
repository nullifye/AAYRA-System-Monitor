import AppKit
import CoreLocation
import CoreWLAN

/// Reads the current Wi-Fi network name (SSID).
/// Since macOS 14 the SSID is only revealed to apps the user has granted Location Services access.
@MainActor
final class WiFiNameProvider: NSObject, CLLocationManagerDelegate {
    enum Access { case notDetermined, granted, denied }

    private let manager = CLLocationManager()
    /// Called when the user answers the permission prompt or changes it in System Settings.
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var access: Access {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        default: .granted
        }
    }

    func requestAccessIfNeeded() {
        if access == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    var currentSSID: String? {
        guard access == .granted else { return nil }
        return CWWiFiClient.shared().interface()?.ssid()
    }

    static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onAuthorizationChange?() }
    }
}
