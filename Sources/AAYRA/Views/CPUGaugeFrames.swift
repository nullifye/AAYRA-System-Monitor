import AppKit

/// A half-circle meter: 0% points left, 50% points up, and 100% points right.
/// Template images follow the menu bar's light, dark and tinted appearances.
@MainActor
enum CPUGaugeFrames {
    static let size = NSSize(width: 22, height: 22)
    private static var frames: [Int: NSImage] = [:]

    static func normalized(_ fraction: Double) -> Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }

    static func target(for fraction: Double, animationEnabled: Bool) -> Double {
        animationEnabled ? normalized(fraction) : 0.25
    }

    static func needleAngle(_ fraction: Double) -> Double {
        .pi * (1 - normalized(fraction))
    }

    static func needleTip(_ fraction: Double) -> CGPoint {
        let angle = needleAngle(fraction)
        return CGPoint(x: 9 + 6.2 * cos(angle), y: 5 + 6.2 * sin(angle))
    }

    static func frame(at percent: Int) -> NSImage {
        let percent = min(100, max(0, percent))
        if let frame = frames[percent] { return frame }
        let fraction = Double(percent) / 100
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: size.width / 18, y: size.height / 18)
            let center = CGPoint(x: 9, y: 5)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineWidth(1.4)
            context.addArc(center: center, radius: 7.7, startAngle: .pi, endAngle: 0, clockwise: true)
            context.strokePath()

            // Five short ticks mark 0, 25, 50, 75 and 100%.
            context.setLineWidth(1)
            for tick in 0...4 {
                let angle = Double(tick) * .pi / 4
                context.move(to: CGPoint(x: center.x + 6.1 * cos(angle), y: center.y + 6.1 * sin(angle)))
                context.addLine(to: CGPoint(x: center.x + 7.7 * cos(angle), y: center.y + 7.7 * sin(angle)))
            }
            context.strokePath()
            context.setLineWidth(1.7)
            context.move(to: center)
            context.addLine(to: needleTip(fraction))
            context.strokePath()
            context.fillEllipse(in: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CPU usage \(percent) percent"
        frames[percent] = image
        return image
    }
}
