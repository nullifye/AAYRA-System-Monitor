import AppKit
import SwiftUI

/// Borderless, transparent window for the floating cards. Borderless windows can't become key by
/// default, which keyboard shortcuts and the detail popovers need.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // each card draws its own depth
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
    private static let targetStep = 22.5           // degrees per frame we aim for before raising fps
    private static let blurThreshold = 0.8

    private let monitor: SystemMonitor
    // Fixed width while spinning, so swapping frames never triggers a menu bar relayout.
    private static let iconLength: CGFloat = 26
    private let statusItem = NSStatusBar.system.statusItem(withLength: StatusItemController.iconLength)
    private let panel = FloatingPanel()
    private var eventMonitors: [Any] = []
    private var panelGeneration = 0
    private lazy var contextMenu: NSMenu = makeContextMenu()

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
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive),
                                               name: .aayraClosePanel, object: nil)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(pause), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(pause), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(accessibilityChanged),
                           name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        updateLabel()
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
        RunLoop.main.add(timer, forMode: .common)   // keeps spinning while menus are tracking
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
            angle = 0                                         // animation switched off: rest upright
            statusItem.button?.image = SpinnerFrames.frame(at: 0, blurred: false)
        }
        updateLabel()
        scheduleNextFrame()
    }

    private func updateLabel() {
        let percent = Int((monitor.cpu.total * 100).rounded())
        let showsPercent = showsPercent
        guard percent != lastShownPercent || showsPercent != lastShowsPercent,
              let button = statusItem.button else { return }
        lastShownPercent = percent
        lastShowsPercent = showsPercent
        button.setAccessibilityLabel("CPU usage \(percent) percent")
        if showsPercent {
            button.title = " \(percent)%"
            statusItem.length = NSStatusItem.variableLength
        } else if !button.title.isEmpty || statusItem.length != Self.iconLength {
            button.title = ""
            statusItem.length = Self.iconLength
        }
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
            statusItem.menu = contextMenu
            sender.performClick(nil)       // shows the menu
            statusItem.menu = nil          // restore left-click → panel
        } else if panel.isVisible {
            closePanel()
        } else {
            showPopover()
        }
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
        host.sizingOptions = []            // the window follows the content size via placePanel
        panel.contentView = host
        placePanel(size: host.fittingSize)

        button.highlight(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        installEventMonitors()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        removeEventMonitors()
        statusItem.button?.highlight(false)
        monitor.panelDidClose()
        let generation = panelGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
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
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = min(max(buttonWindow.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let frame = NSRect(x: x.rounded(), y: (visible.maxY - size.height).rounded(), width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Closes on a click anywhere outside the panel (and its detail popovers), or on Escape.
    private func installEventMonitors() {
        removeEventMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] event in
            let location = event.locationInWindow     // screen coordinates for events in other apps
            MainActor.assumeIsolated {
                guard let self else { return }
                // The click that opened the panel can reach this monitor too (the menu bar is drawn by
                // another process); clicks on our own icon are handled by the button instead.
                if let iconFrame = self.statusItem.button?.window?.frame, iconFrame.contains(location) { return }
                self.closePanel()
            }
        }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown],
                                                        handler: { [weak self] event in
            let isEscape = event.type == .keyDown && event.keyCode == 53
            let isKey = event.type == .keyDown
            let window = event.window
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if isEscape { self.closePanel(); return true }
                if isKey { return false }
                let isOurs = window != nil && (window == self.panel || window == self.statusItem.button?.window
                    || (self.panel.childWindows ?? []).contains(window!))
                if !isOurs { self.closePanel() }
                return false
            }
            return swallow ? nil : event
        }) {
            eventMonitors.append(local)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    @objc private func appDidResignActive() { closePanel() }

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

enum SystemActions {
    @MainActor static func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
