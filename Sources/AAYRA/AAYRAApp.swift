import AppKit

@main
@MainActor
enum AAYRAMain {
    static func main() {
        #if DEBUG   // developer tools, left out of release builds to keep the app small
        let args = CommandLine.arguments
        if args.contains("--dump") { dumpStats(); return }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            _ = NSApplication.shared
            DebugRender.run(outputDirectory: args[i + 1]); return
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }

    #if DEBUG
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
        print("RAM:", MemoryHardware.type as Any, MemoryHardware.vendor as Any,
              "top", ProcessSampler().sample(top: 5).memory.map { "\($0.name) \(Format.bytes($0.footprint))" })
        let sampler = ProcessSampler()
        _ = sampler.sample(top: 5)
        Thread.sleep(forTimeInterval: 1)
        print("CPU+:", "clusters", ChipInfo.coreClusters, "gpu", ChipInfo.gpuCores as Any, "model", ChipInfo.model as Any,
              "kernel", ChipInfo.kernel as Any, ChipInfo.build as Any, "procs", sampler.processCount,
              "topCPU", sampler.sample(top: 5).cpu.map { "\($0.name) \(String(format: "%.1f", $0.percent))%" },
              "thermal", ProcessInfo.processInfo.thermalState.rawValue)
        if let d = DiskProvider.sample() {
            print("Volume:", d.fileSystem as Any, "encrypted", d.isEncrypted as Any,
                  "free", Format.diskBytes(d.free), "purgeable", Format.diskBytes(d.purgeable))
            print("Disk:", d.volumeName, Format.diskBytes(d.available), "free of", Format.diskBytes(d.total))
        }
        if let ssd = SSDHealthProvider.sample() {
            print("SSD:", "health", Format.percent(ssd.health), "temp", ssd.temperatureC as Any,
                  "written", Format.diskBytes(Int64(clamping: ssd.bytesWritten)),
                  "read", Format.diskBytes(Int64(clamping: ssd.bytesRead)),
                  "powerOnHours", ssd.powerOnHours, "spare", ssd.availableSpare, "condition", ssd.condition)
            let i = ssd.info
            print("SSD+:", i.model as Any, i.serial as Any, i.firmware as Any, i.interconnect as Any,
                  i.bsdName as Any, i.capacityBytes.map { Format.diskBytes($0) } as Any,
                  "spare", ssd.availableSpare, "/", ssd.availableSpareThreshold, "cycles", ssd.powerCycles,
                  "unsafe", ssd.unsafeShutdowns, "mediaErrors", ssd.mediaErrors)
        } else {
            print("SSD: SMART data unavailable")
        }
        if let b = BatteryProvider.sample() {
            print("Battery:", Format.percent(b.charge), b.state, "toEmpty", b.minutesToEmpty as Any,
                  "toFull", b.minutesToFull as Any, "cycles", b.cycleCount as Any, "/", b.designCycles as Any,
                  "temp", b.temperatureC as Any, "mAh", b.currentCapacity_mAh as Any, "/", b.designCapacity_mAh as Any,
                  "computedHealth", b.computedHealth.map { Format.percent($0) } as Any,
                  "condition", b.condition as Any, "adapterW", b.adapterWatts as Any)
            print("Battery+:", "fullCharge", b.fullChargeCapacity_mAh as Any, "watts", b.powerWatts as Any,
                  "serial", b.serial as Any, "pack", b.packManufacturer as Any, "cells", b.manufacturer as Any,
                  "made", b.manufactureDate as Any, "estimated", b.manufactureDateIsEstimate,
                  "lowPower", ProcessInfo.processInfo.isLowPowerModeEnabled)
            print("Battery++:", "mV", b.voltage_mV as Any, "mA", b.current_mA as Any, "cells", b.cellVoltages_mV,
                  "remaining", b.remaining_mAh as Any, "/", b.rawMax_mAh as Any, "load W", b.systemLoadWatts as Any,
                  "in W", b.adapterInputWatts as Any, "soc", b.dailyMinSoc as Any, b.dailyMaxSoc as Any,
                  "temp", b.lifetimeMinTempC as Any, b.lifetimeMaxTempC as Any, b.lifetimeAvgTempC as Any,
                  "peakA", b.maxChargeCurrent_mA as Any, b.maxDischargeCurrent_mA as Any,
                  "packV", b.minPackVoltage_mV as Any, b.maxPackVoltage_mV as Any, "hours", b.operatingHours as Any,
                  "pf", b.permanentFailure as Any, "disc", b.cellDisconnects as Any,
                  "thermal", b.thermallyLimitedCharging as Any)
        }
        let details = NetworkDetailsProvider.sample(interface: n.interfaceName, isWiFi: n.interfaceKind == "Wi-Fi")
        print("Network+:", "mac", details.macAddress as Any, "mask", details.subnetMask as Any,
              "router", details.router as Any, "dns", details.dnsServers, "search", details.searchDomains,
              "wifi", details.wifi as Any, "expensive", n.isExpensive, "constrained", n.isConstrained,
              "totals", Format.bytes(n.totalDownloaded), Format.bytes(n.totalUploaded))
        print("Network:", n.interfaceKind, n.interfaceName as Any, "v4", n.localIPv4 as Any, "v6", n.localIPv6 as Any,
              "down", Format.rate(n.downloadBytesPerSec), "up", Format.rate(n.uploadBytesPerSec))
    }
    #endif
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
