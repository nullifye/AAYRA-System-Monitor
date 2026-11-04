import AppKit
import SwiftUI

/// `AAYRA --render <dir>` writes PNG previews of the panel (light & dark) and the spinner frames.
@MainActor
enum DebugRender {
    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: outputDirectory)
        let monitor = SystemMonitor()
        // Let a few real samples accumulate so charts have data.
        let deadline = Date().addingTimeInterval(4)
        monitor.start()
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        for scheme in [ColorScheme.light, .dark] {
            let view = PanelView(monitor: monitor)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage { write(image, to: dir.appendingPathComponent("panel-\(scheme == .dark ? "dark" : "light").png")) }
        }

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
