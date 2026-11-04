import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Live Wi-Fi link details from CoreWLAN (SSID and BSSID need Location Services access).
struct WiFiDetails: Equatable {
    var bssid: String?
    var rssi: Int?                 // dBm
    var noise: Int?                // dBm
    var transmitRateMbps: Double?
    var channel: Int?
    var band: String?              // "2.4 GHz", "5 GHz", "6 GHz"
    var channelWidth: String?      // "80 MHz"
    var security: String?
    var standard: String?          // "Wi-Fi 6 (802.11ax)"
    var countryCode: String?

    var signalQuality: String? {
        guard let rssi else { return nil }
        switch rssi {
        case (-50)...: return "Excellent"
        case (-60)...: return "Good"
        case (-70)...: return "Fair"
        default: return "Weak"
        }
    }
}

/// Addressing details for the active interface.
struct NetworkDetails: Equatable {
    var macAddress: String?
    var subnetMask: String?
    var router: String?
    var dnsServers: [String] = []
    var searchDomains: [String] = []
    var linkSpeedMbps: Int?        // wired links only (Wi-Fi uses the transmit rate)
    var wifi: WiFiDetails?
}

enum NetworkDetailsProvider {
    static func sample(interface: String?, isWiFi: Bool) -> NetworkDetails {
        var details = NetworkDetails()
        guard let interface else { return details }

        let store = SCDynamicStoreCreate(nil, "AAYRA" as CFString, nil, nil)
        func value(_ key: String) -> [String: Any]? {
            store.flatMap { SCDynamicStoreCopyValue($0, key as CFString) as? [String: Any] }
        }
        details.router = value("State:/Network/Global/IPv4")?["Router"] as? String
        let dns = value("State:/Network/Global/DNS")
        details.dnsServers = dns?["ServerAddresses"] as? [String] ?? []
        details.searchDomains = dns?["SearchDomains"] as? [String] ?? []
        details.subnetMask = (value("State:/Network/Interface/\(interface)/IPv4")?["SubnetMasks"] as? [String])?.first

        let link = linkInfo(for: interface)
        details.macAddress = link.mac
        if !isWiFi, let baud = link.baudRate, baud > 0 { details.linkSpeedMbps = Int(baud / 1_000_000) }
        if isWiFi { details.wifi = wifiDetails() }
        return details
    }

    /// MAC address and link speed from the interface's AF_LINK entry.
    private static func linkInfo(for interface: String) -> (mac: String?, baudRate: UInt64?) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (nil, nil) }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK,
                  String(cString: ifa.ifa_name) == interface else { continue }
            let mac: String? = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
                guard dl.pointee.sdl_alen == 6 else { return nil }
                // The address bytes follow the interface name inside sdl_data.
                let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(dl.pointee.sdl_nlen)
                let base = UnsafeRawPointer(dl).advanced(by: offset)
                return (0..<6).map { String(format: "%02x", base.load(fromByteOffset: $0, as: UInt8.self)) }
                    .joined(separator: ":")
            }
            let baud = ifa.ifa_data.map { $0.assumingMemoryBound(to: if_data.self).pointee.ifi_baudrate }
            return (mac, baud.map(UInt64.init))
        }
        return (nil, nil)
    }

    private static func wifiDetails() -> WiFiDetails? {
        guard let wifi = CWWiFiClient.shared().interface() else { return nil }
        var d = WiFiDetails()
        d.bssid = wifi.bssid()
        let rssi = wifi.rssiValue(), noise = wifi.noiseMeasurement()
        d.rssi = rssi != 0 ? rssi : nil
        d.noise = noise != 0 ? noise : nil
        let rate = wifi.transmitRate()
        d.transmitRateMbps = rate > 0 ? rate : nil
        if let channel = wifi.wlanChannel() {
            d.channel = channel.channelNumber
            d.band = [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"][channel.channelBand.rawValue]
            d.channelWidth = [1: "20 MHz", 2: "40 MHz", 3: "80 MHz", 4: "160 MHz", 5: "320 MHz"][channel.channelWidth.rawValue]
        }
        d.security = [0: "Open", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal", 4: "WPA2 Personal",
                      5: "Personal", 6: "Dynamic WEP", 7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise",
                      9: "WPA2 Enterprise", 10: "Enterprise", 11: "WPA3 Personal", 12: "WPA3 Enterprise",
                      13: "WPA2/WPA3 Personal", 14: "Enhanced Open (OWE)", 15: "OWE Transition"][wifi.security().rawValue]
        d.standard = [1: "802.11a", 2: "802.11b", 3: "802.11g", 4: "Wi-Fi 4 (802.11n)", 5: "Wi-Fi 5 (802.11ac)",
                      6: "Wi-Fi 6 (802.11ax)", 7: "Wi-Fi 7 (802.11be)"][wifi.activePHYMode().rawValue]
        d.countryCode = wifi.countryCode()
        return d
    }
}
