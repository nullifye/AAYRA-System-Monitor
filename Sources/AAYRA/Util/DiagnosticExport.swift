import AppKit
import UniformTypeIdentifiers

/// The three sensitive categories must be selected anew for every export.
@MainActor
enum DiagnosticExport {
    static func show(monitor: SystemMonitor) {
        let snapshot = DiagnosticSnapshot(monitor: monitor)
        // The dashboard is a non-activating, high-level panel. A standard save dialog opened
        // from it can land behind the currently active app and cannot receive clicks.
        NotificationCenter.default.post(name: .aayraClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.level = .floating
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "AAYRA-Diagnostics.txt"
        panel.message = "Only the selected sensitive details will be included. Nothing is uploaded."

        let ip = NSButton(checkboxWithTitle: "Include IP addresses", target: nil, action: nil)
        let serial = NSButton(checkboxWithTitle: "Include serial numbers", target: nil, action: nil)
        let processes = NSButton(checkboxWithTitle: "Include process names", target: nil, action: nil)
        ip.state = .off
        serial.state = .off
        processes.state = .off
        let stack = NSStackView(views: [ip, serial, processes])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 94))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor, constant: -6),
        ])
        panel.accessoryView = accessory

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let options = DiagnosticSnapshot.Options(
                includeIPAddresses: ip.state == .on,
                includeSerialNumbers: serial.state == .on,
                includeProcessNames: processes.state == .on)
            do {
                try snapshot.text(options: options).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t save diagnostic snapshot"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}
