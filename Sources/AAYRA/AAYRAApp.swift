import AppKit

@main
@MainActor
enum AAYRAMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") { dumpStats(); return }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            _ = NSApplication.shared
            DebugRender.run(outputDirectory: args[i + 1]); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }

    /// `AAYRA --dump` prints one round of readings, handy for checking them against system tools.
    private static func dumpStats() {
        let cpu = CPUProvider(), net = NetworkProvider()
        _ = cpu.sample(); _ = net.sample()
        Thread.sleep(forTimeInterval: 1)
        let c = cpu.sample(), n = net.sample()
        print("Machine:", MachineInfo.productName, "|", MachineInfo.chip, "|", MachineInfo.osVersion,
              "| up", Format.uptime(since: MachineInfo.bootDate))
        if let c {
            print("CPU:", Format.percent(c.total), "user", Format.percent(c.user), "sys", Format.percent(c.system),
                  "cores", c.perCore.map { Format.percent($0) }, "P/E", cpu.performanceCores, cpu.efficiencyCores)
        }
        if let m = MemoryProvider.sample() {
            print("Memory:", Format.bytes(m.used), "of", Format.bytes(m.total), "app", Format.bytes(m.app),
                  "wired", Format.bytes(m.wired), "compressed", Format.bytes(m.compressed),
                  "cached", Format.bytes(m.cached), "swap", Format.bytes(m.swapUsed), "pressure", m.pressure)
        }
        if let d = DiskProvider.sample() {
            print("Disk:", d.volumeName, Format.diskBytes(d.available), "free of", Format.diskBytes(d.total))
        }
        if let b = BatteryProvider.sample() {
            print("Battery:", Format.percent(b.charge), b.state, "toEmpty", b.minutesToEmpty as Any,
                  "toFull", b.minutesToFull as Any, "cycles", b.cycleCount as Any, "/", b.designCycles as Any,
                  "temp", b.temperatureC as Any, "mAh", b.currentCapacity_mAh as Any, "/", b.designCapacity_mAh as Any,
                  "computedHealth", b.computedHealth.map { Format.percent($0) } as Any,
                  "condition", b.condition as Any, "adapterW", b.adapterWatts as Any)
        }
        print("Network:", n.interfaceKind, n.interfaceName as Any, "v4", n.localIPv4 as Any, "v6", n.localIPv6 as Any,
              "down", Format.rate(n.downloadBytesPerSec), "up", Format.rate(n.uploadBytesPerSec))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SystemMonitor?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = SystemMonitor()
        monitor.start()
        self.monitor = monitor
        let controller = StatusItemController(monitor: monitor)
        statusController = controller
        if CommandLine.arguments.contains("--show-panel") {   // debugging aid
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { controller.showPopover() }
        }
    }
}
