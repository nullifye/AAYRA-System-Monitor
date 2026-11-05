import Testing

@testable import AAYRA

/// The alert rules, driven with simulated readings and time (no notifications are sent).
struct AlertRulesTests {
    private var rules = AlertRules()

    private mutating func fire(_ s: AlertSnapshot, _ settings: AlertSettings, at t: Double) -> [AlertKind] {
        rules.evaluate(s, settings: settings, now: t)
    }

    // MARK: Battery

    @Test mutating func batteryFiresOnceBelowThresholdOnBattery() {
        let on = AlertSettings(batteryLow: true, batteryThreshold: 20)
        #expect(fire(AlertSnapshot(batteryCharge: 0.25, onBattery: true), on, at: 0).isEmpty)
        #expect(fire(AlertSnapshot(batteryCharge: 0.20, onBattery: true), on, at: 1) == [.batteryLow])
        #expect(fire(AlertSnapshot(batteryCharge: 0.15, onBattery: true), on, at: 2).isEmpty)  // once only
    }

    @Test mutating func batteryIgnoredWhilePluggedIn() {
        let on = AlertSettings(batteryLow: true, batteryThreshold: 20)
        #expect(fire(AlertSnapshot(batteryCharge: 0.10, onBattery: false), on, at: 0).isEmpty)
    }

    @Test mutating func batteryRearmsAfterChargingOrRecovering() {
        let on = AlertSettings(batteryLow: true, batteryThreshold: 20)
        #expect(fire(AlertSnapshot(batteryCharge: 0.19, onBattery: true), on, at: 0) == [.batteryLow])
        // Hovering just above the threshold (within the 5-point margin) doesn't re-arm.
        _ = fire(AlertSnapshot(batteryCharge: 0.22, onBattery: true), on, at: 1)
        #expect(fire(AlertSnapshot(batteryCharge: 0.19, onBattery: true), on, at: 2).isEmpty)
        // Plugging in re-arms; unplugging below the threshold alerts again.
        _ = fire(AlertSnapshot(batteryCharge: 0.19, onBattery: false), on, at: 3)
        #expect(fire(AlertSnapshot(batteryCharge: 0.18, onBattery: true), on, at: 4) == [.batteryLow])
    }

    @Test mutating func noBatteryNoAlert() {
        let on = AlertSettings(batteryLow: true)
        #expect(fire(AlertSnapshot(batteryCharge: nil), on, at: 0).isEmpty)
    }

    // MARK: Disk

    @Test mutating func diskFiresBelowThresholdAndRearmsWithMargin() {
        let on = AlertSettings(diskFull: true, diskThresholdGB: 10)
        let gb: Int64 = 1_000_000_000
        #expect(fire(AlertSnapshot(diskAvailable: 11 * gb), on, at: 0).isEmpty)
        #expect(fire(AlertSnapshot(diskAvailable: 9 * gb), on, at: 1) == [.diskFull])
        _ = fire(AlertSnapshot(diskAvailable: 12 * gb), on, at: 2)  // < 12.5 GB: not re-armed yet
        #expect(fire(AlertSnapshot(diskAvailable: 9 * gb), on, at: 3).isEmpty)
        _ = fire(AlertSnapshot(diskAvailable: 13 * gb), on, at: 4)  // > 12.5 GB: re-armed
        #expect(fire(AlertSnapshot(diskAvailable: 9 * gb), on, at: 5) == [.diskFull])
    }

    // MARK: Memory

    @Test mutating func memoryNeedsAMinuteOfPressure() {
        let on = AlertSettings(memoryPressure: true)
        #expect(fire(AlertSnapshot(memoryPressure: .warning), on, at: 0).isEmpty)
        #expect(fire(AlertSnapshot(memoryPressure: .warning), on, at: 59).isEmpty)
        #expect(fire(AlertSnapshot(memoryPressure: .warning), on, at: 60) == [.memoryPressure])
    }

    @Test mutating func memoryCriticalOnlyIgnoresHigh() {
        let on = AlertSettings(memoryPressure: true, memoryCriticalOnly: true)
        _ = fire(AlertSnapshot(memoryPressure: .warning), on, at: 0)
        #expect(fire(AlertSnapshot(memoryPressure: .warning), on, at: 120).isEmpty)
        _ = fire(AlertSnapshot(memoryPressure: .critical), on, at: 121)
        #expect(fire(AlertSnapshot(memoryPressure: .critical), on, at: 181) == [.memoryPressure])
    }

    @Test mutating func memoryRepeatsOnlyAfterCalmAndCooldown() {
        let on = AlertSettings(memoryPressure: true)
        _ = fire(AlertSnapshot(memoryPressure: .warning), on, at: 0)
        #expect(fire(AlertSnapshot(memoryPressure: .warning), on, at: 60) == [.memoryPressure])
        // Calm for over a minute re-arms, but the 30-minute cooldown still holds.
        _ = fire(AlertSnapshot(memoryPressure: .normal), on, at: 100)
        _ = fire(AlertSnapshot(memoryPressure: .normal), on, at: 200)
        _ = fire(AlertSnapshot(memoryPressure: .warning), on, at: 300)
        #expect(fire(AlertSnapshot(memoryPressure: .warning), on, at: 400).isEmpty)
        #expect(fire(AlertSnapshot(memoryPressure: .warning), on, at: 1_900) == [.memoryPressure])
    }

    // MARK: CPU

    @Test mutating func cpuFiresAfterTheChosenMinutes() {
        let on = AlertSettings(cpuBusy: true, cpuMinutes: 5)
        #expect(fire(AlertSnapshot(cpu: 0.95), on, at: 0).isEmpty)
        #expect(fire(AlertSnapshot(cpu: 0.95), on, at: 299).isEmpty)
        #expect(fire(AlertSnapshot(cpu: 0.95), on, at: 300) == [.cpuBusy])
    }

    @Test mutating func cpuDipsAbove75DontRestartTheClock() {
        let on = AlertSettings(cpuBusy: true, cpuMinutes: 2)
        _ = fire(AlertSnapshot(cpu: 0.95), on, at: 0)
        _ = fire(AlertSnapshot(cpu: 0.82), on, at: 60)  // a dip, still "busy"
        #expect(fire(AlertSnapshot(cpu: 0.97), on, at: 120) == [.cpuBusy])
    }

    @Test mutating func cpuDropBelow75RestartsTheClock() {
        let on = AlertSettings(cpuBusy: true, cpuMinutes: 2)
        _ = fire(AlertSnapshot(cpu: 0.95), on, at: 0)
        _ = fire(AlertSnapshot(cpu: 0.40), on, at: 60)  // genuinely calm
        _ = fire(AlertSnapshot(cpu: 0.95), on, at: 61)
        #expect(fire(AlertSnapshot(cpu: 0.95), on, at: 120).isEmpty)
        #expect(fire(AlertSnapshot(cpu: 0.95), on, at: 181) == [.cpuBusy])
    }

    // MARK: Settings

    @Test mutating func everythingOffByDefault() {
        let off = AlertSettings()
        let bad = AlertSnapshot(batteryCharge: 0.01, onBattery: true, diskAvailable: 1, memoryPressure: .critical, cpu: 1)
        for t in stride(from: 0.0, through: 3_600, by: 60) {
            #expect(fire(bad, off, at: t).isEmpty)
        }
    }

    @Test mutating func turningAnAlertOffAndOnStartsFresh() {
        let on = AlertSettings(diskFull: true, diskThresholdGB: 10)
        #expect(fire(AlertSnapshot(diskAvailable: 1), on, at: 0) == [.diskFull])
        _ = fire(AlertSnapshot(diskAvailable: 1), AlertSettings(), at: 1)  // switched off
        #expect(fire(AlertSnapshot(diskAvailable: 1), on, at: 2) == [.diskFull])  // switched on again
    }
}
