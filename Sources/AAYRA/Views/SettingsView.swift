import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window, opened from the gear button or the menu bar icon's right-click menu.
@MainActor
enum SettingsWindow {
    private static var window: NSPanel?

    /// Settings is a non-activating panel, like the floating panel: it comes to the front and takes
    /// keyboard input without activating AAYRA. (On current macOS an app can't force itself active,
    /// and a normal window opened from the floating panel would appear behind the app you're using.)
    static func show() {
        NotificationCenter.default.post(name: .aayraClosePanel, object: nil)
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(
                contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: true)
            panel.contentViewController = host
            panel.title = "AAYRA Settings"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false  // panels hide when their app deactivates by default
            panel.becomesKeyOnlyIfNeeded = false
            panel.setContentSize(host.view.fittingSize)  // size first, so centring uses the real height
            panel.center()
            window = panel
        }
        window?.orderFrontRegardless()  // in front of the app you're using
        window?.makeKey()
    }
}

/// System Settings–style grouped form.
struct SettingsView: View {
    @AppStorage(AppSettings.Key.animateIcon) private var animateIcon = true
    @AppStorage(AppSettings.Key.showPercentInMenuBar) private var showPercent = false
    @AppStorage(AppSettings.Key.showNetworkInMenuBar) private var showNetworkSpeed = false
    @AppStorage(AppSettings.Key.checkForUpdates) private var checkForUpdates = false
    private var updates = UpdateChecker.shared
    @AppStorage(AppSettings.Key.shortcut) private var shortcut = AppSettings.Shortcut.optionCommandM.rawValue
    @AppStorage(AppSettings.Key.refreshInterval) private var refreshInterval = 1.0
    @AppStorage(AppSettings.Key.temperatureUnit) private var temperatureUnit = AppSettings.TemperatureUnit.system.rawValue
    @AppStorage(AppSettings.Key.fetchPublicIP) private var fetchPublicIP = true
    @AppStorage(AppSettings.Key.showsSection(.cpu)) private var showCPU = true
    @AppStorage(AppSettings.Key.showsSection(.gpu)) private var showGPU = false  // off by default
    @AppStorage(AppSettings.Key.showsSection(.storage)) private var showStorage = true
    @AppStorage(AppSettings.Key.showsSection(.memory)) private var showMemory = true
    @AppStorage(AppSettings.Key.showsSection(.battery)) private var showBattery = true
    @AppStorage(AppSettings.Key.showsSection(.network)) private var showNetwork = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let hasBattery = BatteryProvider.sample() != nil
    private let hasGPU = GPUProvider.sample() != nil
    private let version = AppInfo.version

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("AAYRA").font(.title2.weight(.semibold))
                            Text(version)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text("Menu bar system monitor")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker("Open panel from any app", selection: $shortcut) {
                    ForEach(AppSettings.Shortcut.allCases, id: \.rawValue) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text(
                    "⌥⌘M is also “Minimize All” in many apps; while AAYRA runs, it opens the panel instead. Pick another shortcut if you use that."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Animate icon", isOn: $animateIcon)
                Toggle(
                    "Show CPU percentage",
                    isOn: Binding(
                        get: { showPercent || !animateIcon },
                        set: { showPercent = $0 }
                    )
                )
                .disabled(!animateIcon)
                Toggle("Show network speed", isOn: $showNetworkSpeed)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text(
                    "The turbine spins faster as CPU load rises. With the animation off, the CPU percentage is always shown. Network speed appears as a separate item you can ⌘-drag."
                )
                .foregroundStyle(.secondary)
            }

            Section("Sections") {
                sectionToggle("CPU", symbol: "cpu", color: Palette.cpu, isOn: $showCPU)
                if hasGPU {
                    sectionToggle("GPU", symbol: Palette.gpuSymbol, color: Palette.gpu, isOn: $showGPU)
                }
                sectionToggle("Storage", symbol: "internaldrive.fill", color: Palette.storage, isOn: $showStorage)
                sectionToggle("Memory", symbol: "memorychip", color: Palette.memory, isOn: $showMemory)
                if hasBattery {
                    sectionToggle("Battery", symbol: "battery.75percent", color: Palette.battery, isOn: $showBattery)
                }
                sectionToggle("Network", symbol: "wifi", color: Palette.network, isOn: $showNetwork)
            }

            Section("Data") {
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Picker("Temperature", selection: $temperatureUnit) {
                    Text("System default").tag(AppSettings.TemperatureUnit.system.rawValue)
                    Text("Celsius (°C)").tag(AppSettings.TemperatureUnit.celsius.rawValue)
                    Text("Fahrenheit (°F)").tag(AppSettings.TemperatureUnit.fahrenheit.rawValue)
                }
            }

            Section {
                Toggle("Show public IP address", isOn: $fetchPublicIP)
            } header: {
                Text("Privacy")
            } footer: {
                Text("When on, AAYRA asks api.ipify.org for your public address when the panel opens.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, on in
                        if on { updates.checkNow() }
                    }
                HStack(spacing: 8) {
                    updateStatus
                    Spacer(minLength: 8)
                    if updates.status == .checking {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Now") { updates.checkNow() }
                        .disabled(updates.status == .checking)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(
                    "Asks GitHub once a day whether a newer release exists. Nothing is downloaded or installed, and nothing about you or your Mac is sent."
                )
                .foregroundStyle(.secondary)
            }

            Section("About") {
                HStack {
                    Text("Author")
                    Spacer()
                    Text(AppInfo.author).foregroundStyle(.secondary)
                }
                linkRow(
                    "Source code", symbol: "chevron.left.forwardslash.chevron.right", color: .gray,
                    text: "github.com/nullifye", url: AppInfo.repositoryURL)
                linkRow(
                    "Telegram", symbol: "paperplane.fill", color: .blue,
                    text: "t.me/mohdrafhan", url: AppInfo.authorTelegramURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
    }

    /// Result of the last update check, in one line.
    @ViewBuilder
    private var updateStatus: some View {
        switch updates.status {
        case .idle:
            Text(lastCheckedText ?? "Version \(version)").foregroundStyle(.secondary)
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            Label("AAYRA \(version) is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .noReleases:
            Text("No releases published yet").foregroundStyle(.secondary)
        case .available(let newVersion, let url):
            Link(destination: url) {
                Label("AAYRA \(newVersion) is available ↗", systemImage: "arrow.down.circle.fill")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var lastCheckedText: String? {
        updates.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))" }
    }

    /// A label with a small icon on the left and a clickable link on the right.
    private func linkRow(_ title: String, symbol: String, color: Color, text: String, url: URL) -> some View {
        HStack(spacing: 8) {
            IconBadge(symbol: symbol, color: color, size: 22)
            Text(title)
            Spacer(minLength: 8)
            Link(text + " ↗", destination: url)
        }
    }

    private func sectionToggle(_ title: String, symbol: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                IconBadge(symbol: symbol, color: color, size: 22)
                Text(title)
            }
        }
    }
}
