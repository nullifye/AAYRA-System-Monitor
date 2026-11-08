import Foundation
import Testing

@testable import AAYRA

struct DiagnosticSnapshotTests {
    private func snapshot() -> DiagnosticSnapshot {
        var battery = BatteryStats()
        battery.charge = 0.73
        battery.serial = "BATTERY-SERIAL-SECRET"
        let ssd = SSDHealth(
            health: 0.94, temperatureC: 34, bytesWritten: 0, bytesRead: 0,
            powerOnHours: 4, powerCycles: 2, unsafeShutdowns: 0, mediaErrors: 0,
            availableSpare: 98, availableSpareThreshold: 10,
            info: SSDInfo(
                model: nil, serial: "SSD-SERIAL-SECRET", firmware: nil, interconnect: nil,
                mediumType: nil, bsdName: nil, capacityBytes: nil), hasCriticalWarning: false)
        var network = NetworkStats()
        network.interfaceKind = "Wi-Fi"
        network.interfaceName = "en0"
        network.localIPv4 = "192.0.2.85"
        network.localIPv6 = "2001:db8::85"
        network.vpnInterface = "utun4"
        network.vpnAddress = "198.51.100.85"
        return DiagnosticSnapshot(
            capturedAt: Date(timeIntervalSince1970: 0), version: "1.0", macModel: "Mac",
            chip: "Apple Silicon", macOS: "macOS 15", cpu: CPUStats(total: 0.2),
            thermalState: .nominal, memory: MemoryStats(total: 16_000_000_000),
            disk: DiskStats(volumeName: "PRIVATE-VOLUME", total: 100_000, available: 40_000),
            diskIO: DiskIO(), mountedVolumeCount: 1, ssd: ssd, battery: battery,
            batteryDrainCause: nil, gpu: nil, network: network, publicIP: "203.0.113.85",
            topCPUProcesses: [ProcessCPU(id: "/private/SECRET-PATH", name: "PRIVATE-CPU-APP", percent: 12)],
            topMemoryProcesses: [
                ProcessMemory(
                    id: "/private/SECRET-PATH", name: "PRIVATE-MEM-APP", footprint: 42_000_000)
            ])
    }

    @Test func defaultsExcludeAllSensitiveCategories() {
        let report = snapshot().text()
        #expect(report.contains("AAYRA Diagnostic Snapshot"))
        #expect(report.contains("SSD health:"))
        #expect(report.contains("VPN tunnel detected: Yes"))
        for secret in [
            "192.0.2.85", "2001:db8::85", "198.51.100.85", "203.0.113.85",
            "BATTERY-SERIAL-SECRET", "SSD-SERIAL-SECRET", "PRIVATE-CPU-APP",
            "PRIVATE-MEM-APP", "PRIVATE-VOLUME", "SECRET-PATH", "/private/",
        ] {
            #expect(!report.contains(secret), "Leaked: \(secret)")
        }
    }

    @Test func eachCheckboxOnlyEnablesItsOwnCategory() {
        let snapshot = snapshot()
        let ip = snapshot.text(options: .init(includeIPAddresses: true))
        #expect(ip.contains("192.0.2.85"))
        #expect(ip.contains("2001:db8::85"))
        #expect(ip.contains("198.51.100.85"))
        #expect(ip.contains("203.0.113.85"))
        #expect(!ip.contains("BATTERY-SERIAL-SECRET"))
        #expect(!ip.contains("PRIVATE-CPU-APP"))

        let serial = snapshot.text(options: .init(includeSerialNumbers: true))
        #expect(serial.contains("BATTERY-SERIAL-SECRET"))
        #expect(serial.contains("SSD-SERIAL-SECRET"))
        #expect(!serial.contains("192.0.2.85"))
        #expect(!serial.contains("PRIVATE-CPU-APP"))

        let process = snapshot.text(options: .init(includeProcessNames: true))
        #expect(process.contains("PRIVATE-CPU-APP"))
        #expect(process.contains("PRIVATE-MEM-APP"))
        #expect(!process.contains("192.0.2.85"))
        #expect(!process.contains("BATTERY-SERIAL-SECRET"))
        #expect(!process.contains("SECRET-PATH"))
    }

    @Test func processNamesCannotInjectPathsOrReportLines() {
        var snapshot = snapshot()
        snapshot.topCPUProcesses = [
            ProcessCPU(
                id: "/private/secret", name: "/private/secret/Example\nInjected: value", percent: 2)
        ]
        let report = snapshot.text(options: .init(includeProcessNames: true))
        #expect(report.contains("Example Injected: value"))
        #expect(!report.contains("/private/secret"))
        #expect(!report.contains("\nInjected: value"))
    }
}
