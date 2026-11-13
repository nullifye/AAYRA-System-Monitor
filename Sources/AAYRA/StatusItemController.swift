import AppKit
import SwiftUI

/// Borderless, transparent window for the floating cards. Borderless windows can't become key by
/// default, which keyboard shortcuts and the detail popovers need.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // each card draws its own depth
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
}

/// Owns the menu bar item: a turbine that spins faster as CPU load rises, plus the floating panel.
@MainActor
final class StatusItemController: NSObject {
    // Angular speed in degrees per second, from idle to 100 % CPU.
    // Every frame costs a system-side snapshot of the status item (about 0.7 % CPU per fps),
    // so the frame rate is kept as low as the speed allows: about 4 fps idle, 15 fps flat out.
    // Steps stay at or below 30° so the 90°-symmetric blades never appear to spin backwards.
    private static let minSpeed = 30.0
    private static let maxSpeed = 450.0
    private static let maxFPS = 15.0
    private static let minFPS = 4.0
    private static let targetStep = 22.5  // degrees per frame we aim for before raising fps
    private static let blurThreshold = 0.8

    private let monitor: SystemMonitor
    // Fixed width while spinning, so swapping frames never triggers a menu bar relayout.
    private static let iconLength: CGFloat = 26
    // Room for the turbine and a three-digit CPU percentage, even when usage is a single digit.
    private static let iconWithPercentLength: CGFloat = 68
    private let statusItem = NSStatusBar.system.statusItem(withLength: StatusItemController.iconLength)
    private let panel = FloatingPanel()
    private var eventMonitors: [Any] = []
    private var panelGeneration = 0
    private lazy var contextMenu: NSMenu = makeContextMenu()
    /// Optional second menu bar item with live network speed (Settings → Menu Bar).
    private var networkItem: NSStatusItem?
    private var agentItem: NSStatusItem?
    private var lastAgentTitle: NSAttributedString?
    private var lastAgentAppearance: String?
    private let agentWindow = AgentUsageWindow()
    /// System-wide shortcut that toggles the panel (Settings → General).
    private var hotKey: GlobalHotKey?
    private var registeredShortcut: AppSettings.Shortcut?
    private var lastNetworkText = ""
    private static let networkItemLength: CGFloat = 60

    private var frameTimer: Timer?
    private var angle = 0.0
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    private var isScreenAsleep = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lastShownPercent = -1
    private var lastShowsPercent = false

    /// Spins only while the screen is awake and neither Reduce Motion nor the setting turns it off.
    private var isAnimating: Bool { !isScreenAsleep && !reduceMotion && AppSettings.animateIcon }
    /// Without the spin there's no load signal, so the number is shown instead.
    private var showsPercent: Bool { reduceMotion || !AppSettings.animateIcon || AppSettings.showPercentInMenuBar }

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        super.init()

        if let button = statusItem.button {
            button.image = SpinnerFrames.frame(at: 0, blurred: false)
            button.imagePosition = .imageLeading
            button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        // AAYRA usually isn't the active app while the panel is open, so also close it when you
        // switch to another app (⌘-Tab, Dock, Mission Control).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(otherAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: .aayraClosePanel, object: nil)
        // Clicking an alert notification opens the panel.
        NotificationCenter.default.addObserver(
            self, selector: #selector(showPanelFromAlert),
            name: .aayraShowPanel, object: nil)
        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.togglePanel() }
        }
        applyShortcut()
        // Pick up a new shortcut from Settings straight away.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification, object: nil)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(pause), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(pause), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        updateLabel()
        updateAgentItem()
        scheduleNextFrame()
    }

    // MARK: Animation

    private func scheduleNextFrame() {
        frameTimer?.invalidate()
        let load = min(max(monitor.smoothedCPU, 0), 1)
        let speed = Self.minSpeed + (Self.maxSpeed - Self.minSpeed) * load
        let animating = isAnimating
        // Without animation, wake only once per second to refresh the label.
        let fps = animating ? min(Self.maxFPS, max(Self.minFPS, speed / Self.targetStep)) : 1

        let timer = Timer(timeInterval: 1 / fps, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        timer.tolerance = 0.1 / fps
        RunLoop.main.add(timer, forMode: .common)  // keeps spinning while menus are tracking
        frameTimer = timer
    }

    private func advanceFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - lastFrameTime, 0.25)
        lastFrameTime = now

        if isAnimating {
            let load = min(max(monitor.smoothedCPU, 0), 1)
            angle = (angle + (Self.minSpeed + (Self.maxSpeed - Self.minSpeed) * load) * dt)
                .truncatingRemainder(dividingBy: 90)
            let index = Int(angle / SpinnerFrames.degreesPerFrame)
            statusItem.button?.image = SpinnerFrames.frame(at: index, blurred: load > Self.blurThreshold)
        } else if angle != 0, !isScreenAsleep {
            angle = 0  // animation switched off: rest upright
            statusItem.button?.image = SpinnerFrames.frame(at: 0, blurred: false)
        }
        updateLabel()
        updateNetworkItem()
        updateAgentItem()
        scheduleNextFrame()
    }

    /// Shows, updates or removes the network speed item. Runs with the animation timer (at least once a
    /// second) but only redraws when the text changes; a fixed width keeps the menu bar from shifting.
    private func updateNetworkItem() {
        guard AppSettings.showNetworkInMenuBar else {
            if let item = networkItem {
                NSStatusBar.system.removeStatusItem(item)
                networkItem = nil
                lastNetworkText = ""
            }
            return
        }
        let item = networkItem ?? makeNetworkItem()
        let net = monitor.network
        let up = Format.compactRate(net.uploadBytesPerSec), down = Format.compactRate(net.downloadBytesPerSec)
        let text = up + "|" + down
        guard text != lastNetworkText, let button = item.button else { return }
        lastNetworkText = text
        button.image = NetworkSpeedImage.make(up: up, down: down, width: Self.networkItemLength - 4)
        button.setAccessibilityLabel("Network: upload \(up), download \(down)")
    }

    private func makeNetworkItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Self.networkItemLength)
        item.autosaveName = "AAYRANetworkSpeed"  // remembers where the user ⌘-drags it
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        networkItem = item
        return item
    }

    /// A dedicated icon and titled window, independent of the hardware status item/panel.
    private func updateAgentItem() {
        guard AppSettings.showAgentUsageInMenuBar else {
            if let item = agentItem {
                agentWindow.close()
                NSStatusBar.system.removeStatusItem(item)
                agentItem = nil
                lastAgentTitle = nil
                lastAgentAppearance = nil
            }
            return
        }
        if agentItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "AAYRAAgentUsage"
            if let button = item.button {
                button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
                button.target = self
                button.action = #selector(handleAgentClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            agentItem = item
        }
        agentWindow.updateMenuBarMonitoring()
        guard let item = agentItem, let button = item.button else { return }
        let entries = agentWindow.menuBarEntries
        let title = AgentMenuBarText.make(entries)
        if title.length == 0 {
            if button.image == nil || lastAgentTitle != nil {
                let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent Usage")
                icon?.isTemplate = true
                button.image = icon
                button.title = ""
                button.imagePosition = .imageOnly
                item.length = NSStatusItem.squareLength
                lastAgentTitle = nil
                lastAgentAppearance = nil
            }
            button.setAccessibilityLabel("Agent Usage")
            button.toolTip = "Agent Usage"
        } else {
            let appearance = button.effectiveAppearance
            if lastAgentTitle?.isEqual(to: title) != true || lastAgentAppearance != appearance.name.rawValue {
                button.title = ""
                button.image = AgentMenuBarText.image(entries, appearance: appearance)
                button.imagePosition = .imageOnly
                item.length = NSStatusItem.variableLength
                lastAgentTitle = title
                lastAgentAppearance = appearance.name.rawValue
            }
            let label = agentWindow.menuBarAccessibilityLabel
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    @objc private func handleAgentClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let item = agentItem {
            item.menu = contextMenu
            sender.performClick(nil)
            item.menu = nil
        } else {
            closePanel()
            agentWindow.toggle(from: sender)
        }
    }

    @objc private func settingsDidChange() {
        applyShortcut()
        updateAgentItem()
    }

    private func updateLabel() {
        let percent = Int((monitor.cpu.total * 100).rounded())
        let showsPercent = showsPercent
        guard percent != lastShownPercent || showsPercent != lastShowsPercent,
            let button = statusItem.button
        else { return }
        lastShownPercent = percent
        lastShowsPercent = showsPercent
        button.setAccessibilityLabel("CPU usage \(percent) percent")
        if showsPercent {
            statusItem.length = Self.iconWithPercentLength
            button.title = Self.cpuTitle(percent)
        } else if !button.title.isEmpty || statusItem.length != Self.iconLength {
            button.title = ""
            statusItem.length = Self.iconLength
        }
    }

    /// Keep the number close to the turbine; reserve unused digits after the percentage.
    static func cpuTitle(_ percent: Int) -> String {
        " \(percent)%".padding(toLength: 5, withPad: " ", startingAt: 0)
    }

    @objc private func pause() { isScreenAsleep = true }

    @objc private func resume() {
        isScreenAsleep = false
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        scheduleNextFrame()
    }

    @objc private func accessibilityChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lastShownPercent = -1
        if reduceMotion { statusItem.button?.image = SpinnerFrames.frame(at: 0, blurred: false) }
        updateLabel()
        scheduleNextFrame()
    }

    // MARK: Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            let item = sender == networkItem?.button ? networkItem! : statusItem
            item.menu = contextMenu
            sender.performClick(nil)  // shows the menu
            item.menu = nil  // restore left-click → panel
        } else if panel.isVisible {
            closePanel()
        } else {
            showPopover()
        }
    }

    @objc private func applyShortcut() {
        let shortcut = AppSettings.shortcut
        guard shortcut != registeredShortcut else { return }
        registeredShortcut = shortcut
        hotKey?.register(shortcut)
    }

    /// Opens the panel, or closes it if it's already open (the keyboard shortcut).
    func togglePanel() {
        if panel.isVisible { closePanel() } else { showPopover() }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        panelGeneration += 1
        monitor.panelDidOpen()
        // The SwiftUI panel exists only while it is visible, so nothing re-renders in the background.
        let root = PanelView(monitor: monitor, detailEdge: detailEdge(for: button)) { [weak self] size in
            self?.placePanel(size: size)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []  // the window follows the content size via placePanel
        panel.contentView = host
        placePanel(size: host.fittingSize)

        button.highlight(true)
        panel.alphaValue = 0
        // No app activation needed: a non-activating panel takes keyboard focus (Escape, ⌘Q, ⌘,)
        // while the app you were using stays active, the way Spotlight's panel works.
        panel.makeKeyAndOrderFront(nil)
        #if DEBUG
            DebugLayers.dumpLater(panel, name: "main-panel")
        #endif
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        installEventMonitors()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        DetailPresenter.shared.closeAll()
        removeEventMonitors()
        statusItem.button?.highlight(false)
        monitor.panelDidClose()
        let generation = panelGeneration
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // Skip if the panel was reopened while fading out.
                    guard let self, self.panelGeneration == generation else { return }
                    self.panel.orderOut(nil)
                    self.panel.contentView = nil
                }
            })
    }

    /// Keeps the panel just below the menu bar, centred on the icon and inside the screen,
    /// with its top edge fixed as the content grows or shrinks.
    private func placePanel(size: CGSize) {
        guard size.width > 0, size.height > 0, let buttonWindow = statusItem.button?.window,
            let screen = buttonWindow.screen ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let x = min(max(buttonWindow.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let frame = NSRect(x: x.rounded(), y: (visible.maxY - size.height).rounded(), width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Closes on a click anywhere outside the panel (and its detail popovers), or on Escape.
    private func installEventMonitors() {
        removeEventMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                let location = event.locationInWindow  // screen coordinates for events in other apps
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The click that opened the panel can reach this monitor too (the menu bar is drawn by
                    // another process); clicks on our own icon are handled by the button instead.
                    let icons = [
                        self.statusItem.button?.window?.frame, self.networkItem?.button?.window?.frame,
                        self.agentItem?.button?.window?.frame,
                    ]
                    if icons.contains(where: { $0?.contains(location) == true }) { return }
                    self.closePanel()
                }
            })
        {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                let isEscape = event.type == .keyDown && event.keyCode == 53
                let isKey = event.type == .keyDown
                let window = event.window
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    if isEscape { self.closePanel(); return true }
                    if isKey { return false }
                    let isOurs =
                        window != nil
                        && (window == self.panel || window == self.statusItem.button?.window
                            || window == self.networkItem?.button?.window
                            || (self.panel.childWindows ?? []).contains(window!))
                    if !isOurs { self.closePanel() }
                    return false
                }
                return swallow ? nil : event
            })
        {
            eventMonitors.append(local)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    @objc private func appDidResignActive() { closePanel() }

    @objc private func showPanelFromAlert() {
        if !panel.isVisible { showPopover() }
    }

    @objc private func otherAppActivated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { closePanel() }
    }

    /// Detail panels open beside the main panel, on the side with room for them.
    private func detailEdge(for button: NSStatusBarButton) -> Edge {
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return .leading }
        let visible = screen.visibleFrame
        let half = Metrics.panelWidth / 2 + 12
        let leftRoom = window.frame.midX - half - visible.minX
        let rightRoom = visible.maxX - (window.frame.midX + half)
        return leftRoom >= Metrics.detailWidth || leftRoom >= rightRoom ? .leading : .trailing
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let monitorItem = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        monitorItem.target = self
        menu.addItem(monitorItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AAYRA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func openActivityMonitor() { SystemActions.openActivityMonitor() }
    @objc private func openSettings() { SettingsWindow.show() }
}

enum AgentMenuBarText {
    /// A compact column per agent: small name above a larger percentage, in a 22-point menu bar.
    static func image(_ agents: [(name: String, percent: Double?)], appearance: NSAppearance) -> NSImage {
        let nameFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let columns = agents.map { agent in
            let value = agent.percent.map { "\(Int($0.rounded()))%" } ?? "—"
            let name = NSAttributedString(
                string: agent.name, attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor])
            let percent = NSAttributedString(
                string: value,
                attributes: [.font: valueFont, .foregroundColor: agent.percent.map(percentageColor) ?? NSColor.labelColor])
            return (name: name, percent: percent, width: ceil(max(name.size().width, percent.size().width)))
        }
        let gap: CGFloat = 8
        let width = columns.reduce(CGFloat(4)) { $0 + $1.width } + CGFloat(max(0, columns.count - 1)) * gap
        return NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 2
                for column in columns {
                    column.name.draw(at: NSPoint(x: x + (column.width - column.name.size().width) / 2, y: 12))
                    column.percent.draw(at: NSPoint(x: x + (column.width - column.percent.size().width) / 2, y: 0))
                    x += column.width + gap
                }
            }
            return true
        }
    }

    static func percentageColor(_ percent: Double) -> NSColor {
        percent <= 10 ? .systemRed : percent <= 30 ? .systemOrange : .labelColor
    }

    static func make(_ agents: [(name: String, percent: Double?)]) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        for (index, agent) in agents.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: base)) }
            text.append(NSAttributedString(string: agent.name + " ", attributes: base))
            var attributes = base
            if let percent = agent.percent { attributes[.foregroundColor] = percentageColor(percent) }
            let value = agent.percent.map { "\(Int($0.rounded()))%" } ?? "—"
            text.append(NSAttributedString(string: value, attributes: attributes))
        }
        return text
    }
}

/// Two-line upload/download text for the menu bar, drawn as a template image so it follows
/// light, dark and tinted menu bars.
enum NetworkSpeedImage {
    static func make(up: String, down: String, width: CGFloat) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let value: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: right]
        let arrow: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
            let lineHeight: CGFloat = 11
            for (row, (symbol, text)) in [("↑", up), ("↓", down)].enumerated() {
                let y = row == 0 ? lineHeight : 0
                (symbol as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: arrow)
                (text as NSString).draw(
                    in: NSRect(x: 9, y: y, width: rect.width - 9, height: lineHeight),
                    withAttributes: value)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum SystemActions {
    /// System Settings panes AAYRA links to.
    enum SettingsPane: String {
        case storage = "com.apple.settings.Storage"
        case battery = "com.apple.Battery-Settings.extension"
        case network = "com.apple.Network-Settings.extension"
        case wifi = "com.apple.wifi-settings-extension"
    }

    @MainActor static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.raf.aayra") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor static func openSettings(_ pane: SettingsPane) {
        if let url = URL(string: "x-apple.systempreferences:\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor static func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
