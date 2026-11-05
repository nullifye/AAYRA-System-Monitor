import AppKit
import SwiftUI

// Network: the card in the panel and its detail panel.

struct NetworkCard: View {
    let monitor: SystemMonitor
    @State private var copiedValue: String?
    @AppStorage(AppSettings.Key.fetchPublicIP) private var fetchPublicIP = true
    #if DEBUG
        @Environment(\.isSnapshot) private var isSnapshot
    #else
        private let isSnapshot = false  // screenshots are a debug-only feature
    #endif

    var body: some View {
        let net = monitor.network
        Card(symbol: net.symbol, tint: net.isConnected ? Palette.network : .gray) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsPermissionButton && !isSnapshot {
                    Button {
                        monitor.requestWiFiNameAccess()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(
                        monitor.wifiAccess == .denied
                            ? "Allow Location Services in System Settings to show the Wi-Fi name"
                            : "Show the Wi-Fi name (macOS asks for Location Services access)")
                }
                if net.isVPNConnected {
                    Text("VPN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.network.gradient, in: Capsule())
                        .help("VPN connected (\(net.vpnInterface ?? ""))")
                        .accessibilityLabel("VPN connected")
                }
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rate("arrow.down", net.downloadBytesPerSec, Palette.download)
                rate("arrow.up", net.uploadBytesPerSec, Palette.upload)
            }
        } details: {
            DualSparkline(download: monitor.downloadHistory, upload: monitor.uploadHistory, height: 22)
            HStack(spacing: 6) {
                address("Local", isSnapshot ? "192.168.1.20" : net.localIPv4 ?? net.localIPv6)
                Spacer(minLength: 4)
                if fetchPublicIP { publicAddress }
            }
        }
    }

    private var publicAddress: some View {
        HStack(spacing: 2) {
            address(
                "Public", isSnapshot ? "203.0.113.42" : monitor.publicIP,
                loading: monitor.isFetchingPublicIP, alignment: .trailing)
            Button {
                monitor.refreshPublicIP(force: true)
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption2)
            }
            .buttonStyle(.plain)
            .disabled(monitor.isFetchingPublicIP)
            .help("Refresh public IP")
        }
    }

    private var title: String {
        let net = monitor.network
        guard net.isConnected else { return "Offline" }
        if isSnapshot, monitor.wifiName != nil { return "Home Wi-Fi" }
        return monitor.wifiName ?? net.interfaceKind
    }

    private var showsPermissionButton: Bool {
        monitor.network.interfaceKind == "Wi-Fi" && monitor.wifiName == nil && monitor.wifiAccess != .granted
    }

    private func rate(_ symbol: String, _ value: Double, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.callout.weight(.bold))
                .foregroundStyle(color)
            BigValue(Format.rate(value), size: 18)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func address(
        _ label: String, _ value: String?, loading: Bool = false,
        alignment: Alignment = .leading
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
            if loading && value == nil {
                ProgressView().controlSize(.mini)
            } else if let value {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copiedValue = value
                    Task {
                        try? await Task.sleep(for: .seconds(1.3))
                        if copiedValue == value { copiedValue = nil }
                    }
                } label: {
                    // Turns bold for a moment to confirm the copy. A hidden bold copy reserves
                    // the width so nothing shifts, and the change is instant (no animation).
                    ZStack(alignment: alignment) {
                        Text(value).fontWeight(.bold).hidden()
                        Text(value).fontWeight(copiedValue == value ? .bold : .regular)
                    }
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .transaction { $0.animation = nil }
                }
                .buttonStyle(.plain)
                .help("Click to copy \(label.lowercased()) IP")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

struct NetworkDetail: View {
    let monitor: SystemMonitor
    @AppStorage(AppSettings.Key.historyRange) private var range = HistoryRange.minute

    var body: some View {
        let net = monitor.network
        let info = monitor.networkDetails
        let isWiFi = net.interfaceKind == "Wi-Fi"
        DetailPanel(
            symbol: net.symbol, tint: net.isConnected ? Palette.network : .gray,
            title: "Network", subtitle: subtitle,
            actions: [
                DetailAction(title: isWiFi ? "Wi-Fi Settings…" : "Network Settings…", symbol: "gearshape") {
                    SystemActions.openSettings(isWiFi ? .wifi : .network)
                }
            ]
        ) {
            DetailSection("Traffic") {
                HistoryRangePicker(range: $range)
            } content: {
                let down = monitor.downloadSeries, up = monitor.uploadSeries, now = monitor.seriesTime
                HistoryChart(
                    series: [
                        .init(
                            name: "Download", buckets: down.buckets(range.buckets, inLast: range.seconds, now: now),
                            color: Palette.download),
                        .init(
                            name: "Upload", buckets: up.buckets(range.buckets, inLast: range.seconds, now: now),
                            color: Palette.upload),
                    ],
                    range: range
                )
                .padding(.vertical, 2)
                DetailRow("Download", Format.rate(net.downloadBytesPerSec), dot: Palette.download)
                DetailRow("Upload", Format.rate(net.uploadBytesPerSec), dot: Palette.upload)
                DetailRow(
                    "Peak (\(range.spanText))",
                    "↓ \(Format.rate(down.peak(inLast: range.seconds, now: now) ?? 0)) · "
                        + "↑ \(Format.rate(up.peak(inLast: range.seconds, now: now) ?? 0))")
                DetailRow("Since boot", "↓ \(Format.bytes(net.totalDownloaded)) · ↑ \(Format.bytes(net.totalUploaded))")
            }
            if let interface = net.interfaceName {
                DetailSection("Connection") {
                    DetailRow("Interface", "\(net.interfaceKind) (\(interface))")
                    if let vpn = net.vpnInterface {
                        DetailRow("VPN", "Connected (\(vpn))", dot: .green)
                        if let address = net.vpnAddress { DetailRow("VPN address", address, placeholder: "10.8.0.2") }
                    } else {
                        DetailRow("VPN", "Off")
                    }
                    if let mac = info.macAddress { DetailRow("MAC address", mac, placeholder: "a1:b2:c3:d4:e5:f6") }
                    if info.wifi == nil, let speed = info.linkSpeedMbps {
                        DetailRow("Link speed", speed >= 1000 ? "\(speed / 1000) Gbps" : "\(speed) Mbps")
                    }
                    DetailRow("Low Data Mode", Format.onOff(net.isConstrained))
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
                            DetailRow(
                                "Signal", "\(rssi) dBm" + (wifi.signalQuality.map { " (\($0))" } ?? ""),
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
                    if !info.searchDomains.isEmpty {
                        DetailRow("Search domains", info.searchDomains.joined(separator: ", "), placeholder: "home")
                    }
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
