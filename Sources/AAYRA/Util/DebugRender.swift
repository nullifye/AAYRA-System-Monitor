#if DEBUG
import AppKit
import SwiftUI

/// `AAYRA --render <dir>` writes PNG previews of the panel (light & dark) and the spinner frames.
@MainActor
enum DebugRender {
    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: outputDirectory)
        let monitor = SystemMonitor()
        // Let a few real samples accumulate so charts have data.
        let seconds = Double(ProcessInfo.processInfo.environment["AAYRA_RENDER_SECONDS"] ?? "") ?? 4
        let deadline = Date().addingTimeInterval(seconds)
        monitor.start()
        monitor.panelDidOpen()   // also sample processes and network details
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        let wallpaper = LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        func name(_ base: String, _ scheme: ColorScheme) -> URL {
            dir.appendingPathComponent("\(base)-\(scheme == .dark ? "dark" : "light").png")
        }

        // Detail panels drawn as they appear in their popover.
        var details: [(String, AnyView)] = [
            ("cpu", AnyView(CPUDetail(monitor: monitor))),
            ("gpu", AnyView(GPUDetail(monitor: monitor))),
            ("storage", AnyView(StorageDetail(monitor: monitor))),
            ("memory", AnyView(MemoryDetail(memory: monitor.memory, topProcesses: monitor.topProcesses))),
            ("network", AnyView(NetworkDetail(monitor: monitor))),
        ]
        if let battery = monitor.battery {
            details.append(("battery", AnyView(BatteryDetail(battery: battery, lowPowerMode: monitor.isLowPowerMode))))
        }
        func popover(_ content: AnyView) -> some View {
            content
                .background(Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        }

        for scheme in [ColorScheme.light, .dark] {
            // The floating panel over a stand-in wallpaper (cards drawn solid: glass can't be rendered offscreen).
            let panel = PanelView(monitor: monitor)
            render(panel.background(wallpaper), scheme: scheme, to: name("panel", scheme))

            for (base, detail) in details {
                render(popover(detail).padding(28).background(wallpaper), scheme: scheme, to: name("detail-\(base)", scheme))
            }

            // Hero shot: a detail panel open beside the main panel, as in use.
            let hero = HStack(alignment: .top, spacing: 6) {
                popover((details.first { $0.0 == "battery" } ?? details[0]).1).padding(.top, 70)
                panel
            }
            .padding(28)
            .background(wallpaper)
            render(hero, scheme: scheme, to: name("hero", scheme))
        }

        // Menu bar network speed item, drawn black on a light bar and white on a dark bar (as macOS tints templates).
        let speed = NetworkSpeedImage.make(up: "45 KB/s", down: "12.4 MB/s", width: 56)
        let bar = NSImage(size: NSSize(width: 140, height: 30), flipped: false) { _ in
            NSColor(white: 0.92, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 70, height: 30).fill()
            NSColor(white: 0.15, alpha: 1).setFill(); NSRect(x: 70, y: 0, width: 70, height: 30).fill()
            speed.draw(in: NSRect(x: 7, y: 4, width: 56, height: 22))
            if let white = speed.copy() as? NSImage {
                white.lockFocus()
                NSColor.white.set()
                NSRect(origin: .zero, size: white.size).fill(using: .sourceAtop)
                white.unlockFocus()
                white.draw(in: NSRect(x: 77, y: 4, width: 56, height: 22))
            }
            return true
        }
        write(bar, to: dir.appendingPathComponent("menubar-network.png"), scale: 4)

        // Spinner strip: every 3rd frame, sharp then blurred, black on white.
        let frames = stride(from: 0, to: SpinnerFrames.frameCount, by: 3).map { $0 }
        let strip = NSImage(size: NSSize(width: 22 * frames.count, height: 44), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 22 * frames.count, height: 44).fill()
            for (i, f) in frames.enumerated() {
                SpinnerFrames.frame(at: f, blurred: false).draw(in: NSRect(x: 22 * i + 2, y: 24, width: 18, height: 18))
                SpinnerFrames.frame(at: f, blurred: true).draw(in: NSRect(x: 22 * i + 2, y: 2, width: 18, height: 18))
            }
            return true
        }
        write(strip, to: dir.appendingPathComponent("spinner.png"), scale: 4)
        print("Rendered to \(dir.path)")
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        if let image = renderer.nsImage { write(image, to: url, scale: 2) }   // Retina-sharp
    }

    private static func write(_ image: NSImage, to url: URL, scale: CGFloat = 1) {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
