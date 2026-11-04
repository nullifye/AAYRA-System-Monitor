// Generates Resources/AppIcon.icns: the menu bar turbine inside a ring
// made of the five section colours (CPU, Storage, Memory, Battery, Network).
// Usage: swift scripts/make-icon.swift   (run from the project root)
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS system colours (dark appearance) matching the app's Palette.
let ringColors: [UInt32] = [0x0A84FF, 0xBF5AF2, 0xFF375F, 0x30D158, 0x40C8E0]

func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body: Apple's grid puts an 824 pt rounded square inside the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x151B2B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x2B3550), color(0x0D1220)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glow behind the fan.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x5AC8FA, 0.28), color(0x5AC8FA, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 330, options: [])
    // Thin top highlight for depth.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    // Inner edge stroke so the icon holds up on dark backgrounds.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()

    let center = CGPoint(x: 512, y: 512)

    // Ring: five coloured arcs with round caps and small gaps.
    let ringRadius: CGFloat = 300
    let gap: CGFloat = 0.20  // radians
    let segment = (2 * .pi) / CGFloat(ringColors.count)
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    for (i, hex) in ringColors.enumerated() {
        let start = .pi / 2 - CGFloat(i) * segment - gap / 2     // clockwise from 12 o'clock
        let end = start - segment + gap
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18, color: color(hex, 0.55))
        ctx.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: end, clockwise: true)
        ctx.setStrokeColor(color(hex))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Turbine: same swept-blade shape as the menu bar icon, scaled up.
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: -1.4, y: 1.8))
    blade.addCurve(to: CGPoint(x: 2.4, y: 6.5), control1: CGPoint(x: -2.0, y: 4.2), control2: CGPoint(x: -0.4, y: 6.8))
    blade.addCurve(to: CGPoint(x: 1.4, y: 1.8), control1: CGPoint(x: 3.8, y: 5.2), control2: CGPoint(x: 2.8, y: 3.0))
    blade.closeSubpath()
    let scale: CGFloat = 32

    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -.pi / 9)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShadow(offset: CGSize(width: 0, height: -0.25), blur: 0.6, color: color(0x000000, 0.45))
    for _ in 0..<4 {
        ctx.saveGState()
        ctx.addPath(blade)
        ctx.clip()
        let bladeGradient = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xC9D6EA)] as CFArray,
                                       locations: [0, 1])!
        ctx.drawLinearGradient(bladeGradient, start: CGPoint(x: -2, y: 7), end: CGPoint(x: 2, y: 1.5), options: [])
        ctx.restoreGState()
        ctx.rotate(by: .pi / 2)
    }
    ctx.restoreGState()

    // Hub.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x000000, 0.4))
    ctx.setFillColor(color(0xF2F5FA))
    ctx.fillEllipse(in: CGRect(x: center.x - 76, y: center.y - 76, width: 152, height: 152))
    ctx.restoreGState()
    ctx.setFillColor(color(0x1A2236))
    ctx.fillEllipse(in: CGRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56))
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
