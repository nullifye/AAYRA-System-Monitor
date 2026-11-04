import AppKit

/// Pre-rendered template frames of a 4-blade turbine for the menu bar.
/// The blades repeat every 90°, so `frameCount` frames across 90° loop seamlessly.
@MainActor
enum SpinnerFrames {
    static let frameCount = 24
    static let degreesPerFrame = 90.0 / Double(frameCount)
    static let size = NSSize(width: 18, height: 18)

    private static var sharp: [NSImage] = (0..<frameCount).map { makeFrame(index: $0, blurred: false) }
    private static var blurred: [NSImage] = (0..<frameCount).map { makeFrame(index: $0, blurred: true) }

    static func frame(at index: Int, blurred useBlur: Bool) -> NSImage {
        let i = ((index % frameCount) + frameCount) % frameCount
        return useBlur ? blurred[i] : sharp[i]
    }

    private static func makeFrame(index: Int, blurred: Bool) -> NSImage {
        let angle = Double(index) * degreesPerFrame
        let image = NSImage(size: size, flipped: false) { rect in
            draw(angle: angle, in: rect, blurred: blurred)
            return true
        }
        image.isTemplate = true        // follows light/dark/tinted menu bars
        image.accessibilityDescription = "CPU activity"
        return image
    }

    private static func draw(angle: Double, in rect: NSRect, blurred: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)

        // Housing ring.
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.9, dy: 0.9))

        // Blades. Motion blur adds trailing ghost copies at high load.
        let passes: [(offset: Double, alpha: CGFloat)] =
            blurred ? [(-14, 0.18), (-7, 0.4), (0, 1)] : [(0, 1)]
        for pass in passes {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: -CGFloat((angle + pass.offset) * .pi / 180))   // clockwise
            ctx.setFillColor(NSColor.black.withAlphaComponent(pass.alpha).cgColor)
            for _ in 0..<4 {
                ctx.addPath(bladePath)
                ctx.fillPath()
                ctx.rotate(by: .pi / 2)
            }
            ctx.restoreGState()
        }

        // Hub with a small hole so it reads as a fan at 18 pt.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: center.x - 0.9, y: center.y - 0.9, width: 1.8, height: 1.8))
        ctx.setBlendMode(.normal)
    }

    /// One swept blade pointing up from the hub, in center-relative coordinates.
    private static let bladePath: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -1.4, y: 1.8))
        p.addCurve(to: CGPoint(x: 2.4, y: 6.5),
                   control1: CGPoint(x: -2.0, y: 4.2), control2: CGPoint(x: -0.4, y: 6.8))
        p.addCurve(to: CGPoint(x: 1.4, y: 1.8),
                   control1: CGPoint(x: 3.8, y: 5.2), control2: CGPoint(x: 2.8, y: 3.0))
        p.closeSubpath()
        return p
    }()
}
