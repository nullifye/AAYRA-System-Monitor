import Darwin
import Foundation
import Network

struct NetworkStats: Equatable {
    var interfaceName: String?  // e.g. "en0"
    var interfaceKind: String = "Offline"
    var localIPv4: String?
    var localIPv6: String?
    var downloadBytesPerSec: Double = 0
    var uploadBytesPerSec: Double = 0
    var totalDownloaded: UInt64 = 0  // since boot, physical interfaces
    var totalUploaded: UInt64 = 0
    var isExpensive = false  // e.g. iPhone hotspot
    var isConstrained = false  // Low Data Mode
    var supportsIPv6 = false
    var vpnInterface: String?  // e.g. "utun4" while a VPN is connected
    var vpnAddress: String?  // the tunnel's IPv4 address
    var isConnected: Bool { interfaceName != nil }
    var isVPNConnected: Bool { vpnInterface != nil }
}

/// Throughput from 64-bit interface counters, primary interface from NWPathMonitor.
final class NetworkProvider: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _primary: (name: String, kind: String)?
    private var _flags: (expensive: Bool, constrained: Bool, ipv6: Bool) = (false, false, false)
    private var lastCounters: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let iface = path.status == .satisfied ? path.availableInterfaces.first : nil
            let primary = iface.map { ($0.name, Self.describe($0.type)) }
            let flags = (path.isExpensive, path.isConstrained, path.supportsIPv6)
            self.lock.withLock {
                self._primary = primary
                self._flags = flags
            }
        }
        monitor.start(queue: DispatchQueue(label: "aayra.network.path"))
    }

    deinit { monitor.cancel() }

    func sample() -> NetworkStats {
        var stats = NetworkStats()
        let (primary, flags) = lock.withLock { (_primary, _flags) }
        (stats.isExpensive, stats.isConstrained, stats.supportsIPv6) = flags
        stats.interfaceName = primary?.name
        stats.interfaceKind = primary?.kind ?? "Offline"
        if let name = primary?.name {
            (stats.localIPv4, stats.localIPv6) = Self.addresses(for: name)
        }
        if let tunnel = Self.vpnTunnel() {
            stats.vpnInterface = tunnel.name
            stats.vpnAddress = tunnel.address
        }

        let now = ProcessInfo.processInfo.systemUptime
        let counters = Self.readCounters()
        stats.totalDownloaded = counters.rx
        stats.totalUploaded = counters.tx
        if let last = lastCounters, now > last.time {
            let dt = now - last.time
            // Counters can reset if an interface goes away; treat that as zero instead of a spike.
            stats.downloadBytesPerSec = counters.rx >= last.rx ? Double(counters.rx - last.rx) / dt : 0
            stats.uploadBytesPerSec = counters.tx >= last.tx ? Double(counters.tx - last.tx) / dt : 0
        }
        lastCounters = (counters.rx, counters.tx, now)
        return stats
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "Ethernet"
        case .cellular: "Cellular"
        case .loopback: "Loopback"
        default: "Other"
        }
    }

    /// Sums 64-bit byte counters (if_data64) for physical `en*` interfaces.
    private static func readCounters() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                    offset + MemoryLayout<if_msghdr2>.size <= length
                {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil,
                        String(cString: nameBuffer).hasPrefix("en")
                    {
                        rx &+= msg.ifm_data.ifi_ibytes
                        tx &+= msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    /// A connected VPN shows up as a tunnel interface (utun, ipsec, ppp, …) that is up and has an
    /// IPv4 address. macOS keeps a few utun interfaces for its own services, but those only carry
    /// IPv6 link-local addresses, so they're not mistaken for a VPN.
    private static func vpnTunnel() -> (name: String, address: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        let prefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
        let upAndRunning = Int32(IFF_UP | IFF_RUNNING)
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            guard let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET,
                Int32(ifa.ifa_flags) & upAndRunning == upAndRunning,
                prefixes.contains(where: name.hasPrefix)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            return (name, String(cString: host))
        }
        return nil
    }

    private static func addresses(for interface: String) -> (String?, String?) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (nil, nil) }
        defer { freeifaddrs(head) }

        var v4: String?, v6: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, String(cString: ifa.ifa_name) == interface else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if family == AF_INET, v4 == nil {
                v4 = text
            } else if family == AF_INET6, v6 == nil, !text.hasPrefix("fe80") {
                v6 = text  // skip link-local; keep the first global address
            }
        }
        return (v4, v6)
    }
}

enum PublicIPService {
    static func fetch() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !ip.isEmpty, ip.count <= 45
        else { return nil }
        return ip
    }
}
