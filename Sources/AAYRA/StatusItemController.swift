import AppKit
import SwiftUI

/// Owns the menu bar item: a turbine that spins faster as CPU load rises, plus the popover panel.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
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
    private let popover = NSPopover()
    private lazy var contextMenu: NSMenu = makeContextMenu()

    private var frameTimer: Timer?
    private var angle = 0.0
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    private var isScreenAsleep = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lastShownPercent = -1

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

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

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
        let animating = !isScreenAsleep && !reduceMotion
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

        if !isScreenAsleep && !reduceMotion {
            let load = min(max(monitor.smoothedCPU, 0), 1)
            angle = (angle + (Self.minSpeed + (Self.maxSpeed - Self.minSpeed) * load) * dt)
                .truncatingRemainder(dividingBy: 90)
            let index = Int(angle / SpinnerFrames.degreesPerFrame)
            statusItem.button?.image = SpinnerFrames.frame(at: index, blurred: load > Self.blurThreshold)
        }
        updateLabel()
        scheduleNextFrame()
    }

    private func updateLabel() {
        let percent = Int((monitor.cpu.total * 100).rounded())
        guard percent != lastShownPercent, let button = statusItem.button else { return }
        lastShownPercent = percent
        button.setAccessibilityLabel("CPU usage \(percent) percent")
        // With Reduce Motion on, the spin speed can't carry the signal, so show the number instead.
        if reduceMotion {
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
            popover.performClose(nil)
            statusItem.menu = contextMenu
            sender.performClick(nil)       // shows the menu
            statusItem.menu = nil          // restore left-click → popover
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        monitor.panelDidOpen()
        // The SwiftUI panel exists only while the popover is visible, so nothing re-renders in the background.
        let host = NSHostingController(rootView: PanelView(monitor: monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) { statusItem.button?.highlight(true) }
    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        popover.contentViewController = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let monitorItem = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        monitorItem.target = self
        menu.addItem(monitorItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AAYRA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func openActivityMonitor() { SystemActions.openActivityMonitor() }
}

enum SystemActions {
    @MainActor static func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
