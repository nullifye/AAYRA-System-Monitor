import AppKit
import SwiftUI

// The panel's header (Mac model, uptime) and footer (wordmark, version, update badge, buttons).

struct HeaderView: View {
    let monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 6) {
            Text(MachineInfo.productName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text("Up \(Format.uptime(since: monitor.bootDate))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .cardBackground(floating: true)
        .help("\(MachineInfo.chip) · \(MachineInfo.osVersion)")
    }
}

// MARK: - Footer

/// The AAYRA wordmark in the regular system font and a solid colour, with a bevel: a bright inner
/// edge along the top-left of each letter, a dark inner edge along the bottom-right, and a soft drop
/// shadow, so the letters look raised from the tile.
private struct BevelWordmark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let face = dark ? Color(white: 0.85) : Color(white: 0.3)
        Text("AAYRA")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(
                face
                    .shadow(.inner(color: .white.opacity(dark ? 0.9 : 0.7), radius: 0.4, x: 0.6, y: 0.9))
                    .shadow(.inner(color: .black.opacity(dark ? 0.55 : 0.6), radius: 0.4, x: -0.6, y: -0.9))
                    .shadow(.drop(color: .black.opacity(dark ? 0.45 : 0.25), radius: 0.8, x: 0.3, y: 0.8))
            )
            .accessibilityLabel("AAYRA")
    }
}

struct FooterView: View {
    let monitor: SystemMonitor
    private let version = AppInfo.version
    private var updates = UpdateChecker.shared

    init(monitor: SystemMonitor) {
        self.monitor = monitor
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                BevelWordmark()
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            if let update = updates.availableUpdate {
                Button {
                    NSWorkspace.shared.open(update.url)
                } label: {
                    Text("\(update.version) available")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the AAYRA \(update.version) release page")
            }
            Spacer()
            iconButton("Export diagnostic snapshot", symbol: "square.and.arrow.up") {
                DiagnosticExport.show(monitor: monitor)
            }
            iconButton("Settings", symbol: "gearshape") { SettingsWindow.show() }
                .keyboardShortcut(",")
            iconButton("Activity Monitor", symbol: "waveform.path.ecg") { SystemActions.openActivityMonitor() }
            iconButton("Quit AAYRA", symbol: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .cardBackground(floating: true)
    }

    /// Round glass buttons on macOS 26+ (controls are where Liquid Glass belongs), plain icons before.
    @ViewBuilder
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.medium))
                .frame(width: 18, height: 18)
        }
        if #available(macOS 26, *) {
            button
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(title)
                .accessibilityLabel(title)
        } else {
            button
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(title)
                .accessibilityLabel(title)
        }
    }
}
