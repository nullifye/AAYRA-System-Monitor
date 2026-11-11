#if DEBUG
    import AppKit

    /// `AAYRA_DUMP_LAYERS=<dir>`: writes each floating window's layer tree a few seconds after it opens,
    /// to find which layer paints what (glass, backdrops, shadows) without screen-recording permission.
    @MainActor
    enum DebugLayers {
        private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

        /// An app may capture its own windows without screen-recording permission. The window is drawn
        /// alone (so glass shows no backdrop), then composited over white to show its shadows.
        private static func capture(_ window: NSWindow, to path: String) {
            // CGWindowListCreateImage is unavailable to Swift on macOS 15+, but still exported.
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
            guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
            else { return }
            let size = NSSize(width: image.width, height: image.height)
            let composed = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                NSGraphicsContext.current?.cgContext.draw(image, in: rect)
                return true
            }
            guard let tiff = composed.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        /// Dumps at 4 s, and again at 12 s as `<name>-later` (time to change the panel's state in between).
        static func dumpLater(_ window: NSWindow, name: String) {
            dump(window, name: name, after: 4)
            dump(window, name: "\(name)-later", after: 12)
        }

        private static func dump(_ window: NSWindow, name: String, after delay: TimeInterval) {
            guard let dir = ProcessInfo.processInfo.environment["AAYRA_DUMP_LAYERS"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window, window.isVisible, let root = window.contentView?.superview?.layer ?? window.contentView?.layer
                else { return }
                var lines = ["window \(window.frame.integral) opaque=\(window.isOpaque) shadow=\(window.hasShadow)"]
                func walk(_ layer: CALayer, _ depth: Int) {
                    let bg = layer.backgroundColor.map { "bg=\($0.components ?? [])" } ?? ""
                    let shadow = layer.shadowOpacity > 0 ? "shadow=\(layer.shadowOpacity)/\(layer.shadowRadius)" : ""
                    let filters = (layer.filters ?? []).map { filter -> String in
                        guard let object = filter as? NSObject else { return "?" }
                        let name = object.value(forKey: "name") ?? "?"
                        let keys = (object.value(forKey: "inputKeys") as? [String]) ?? []
                        let inputs = keys.compactMap { key in object.value(forKey: key).map { "\(key)=\($0)" } }
                        return "\(name)(\(inputs.joined(separator: ",")))"
                    }.joined(separator: " ")
                    let extras = [
                        bg, shadow, filters, layer.isHidden ? "hidden" : "", layer.opacity < 1 ? "opacity=\(layer.opacity)" : "",
                        layer.compositingFilter.map { "compositing=\($0)" } ?? "",
                    ]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                    lines.append(String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.frame.integral) \(extras)")
                    for sublayer in layer.sublayers ?? [] { walk(sublayer, depth + 1) }
                }
                walk(root, 0)
                try? lines.joined(separator: "\n").write(
                    toFile: (dir as NSString).appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
                capture(window, to: (dir as NSString).appendingPathComponent("\(name).png"))
            }
        }
    }
#endif
