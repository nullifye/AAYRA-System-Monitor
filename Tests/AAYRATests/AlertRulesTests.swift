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

    @Test mutating func acDrainFiresOncePerEventAndRearmsAfterRecovery() {
        let on = AlertSettings(batteryDrain: true)
        let draining = AlertSnapshot(batteryDrainCause: .adapterMayBeUnderpowered)
        #expect(fire(draining, on, at: 0) == [.batteryDrain])
        #expect(fire(AlertSnapshot(batteryDrainCause: .unknown), on, at: 10).isEmpty)
        _ = fire(AlertSnapshot(), on, at: 20)
        #expect(fire(draining, on, at: 50).isEmpty)  // not calm long enough
        _ = fire(AlertSnapshot(), on, at: 60)
        _ = fire(AlertSnapshot(), on, at: 121)  // re-armed, but still cooling down
        #expect(fire(draining, on, at: 130).isEmpty)
        #expect(fire(draining, on, at: 1_801) == [.batteryDrain])
    }

    @Test mutating func acDrainNotificationIsOptIn() {
        let draining = AlertSnapshot(batteryDrainCause: .unknown)
        #expect(fire(draining, AlertSettings(), at: 0).isEmpty)
        #expect(fire(draining, AlertSettings(batteryDrain: true), at: 1) == [.batteryDrain])
    }

    @Test mutating func batteryHeatNeedsTwoMinutesAndCoolsBeforeRearming() {
        let on = AlertSettings(batteryHeat: true)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 0).isEmpty)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 119).isEmpty)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 120) == [.batteryHeat])
        #expect(fire(AlertSnapshot(batteryTemperatureC: 41), on, at: 130).isEmpty)
        _ = fire(AlertSnapshot(batteryTemperatureC: 37), on, at: 140)
        _ = fire(AlertSnapshot(batteryTemperatureC: 37), on, at: 201)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 210).isEmpty)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 330).isEmpty)  // 30-minute cooldown
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 1_921) == [.batteryHeat])
    }

    @Test mutating func batteryHeatMustRemainAboveThresholdForTwoMinutes() {
        let on = AlertSettings(batteryHeat: true)
        _ = fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 0)
        _ = fire(AlertSnapshot(batteryTemperatureC: 39), on, at: 110)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 120).isEmpty)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 40), on, at: 240) == [.batteryHeat])
    }

    @Test mutating func missingHeatReadingDoesNotCountAsSustained() {
        let on = AlertSettings(batteryHeat: true)
        _ = fire(AlertSnapshot(batteryTemperatureC: 41), on, at: 0)
        _ = fire(AlertSnapshot(), on, at: 80)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 41), on, at: 120).isEmpty)
        #expect(fire(AlertSnapshot(batteryTemperatureC: 41), on, at: 240) == [.batteryHeat])
    }

    @Test mutating func ssdWarningFiresOnceAndNeedsConfirmedRecovery() {
        let on = AlertSettings(ssdHealth: true)
        #expect(fire(AlertSnapshot(ssdSMARTWarning: true), on, at: 0) == [.ssdHealth])
        #expect(fire(AlertSnapshot(ssdSMARTWarning: true), on, at: 60).isEmpty)
        _ = fire(AlertSnapshot(ssdSMARTWarning: nil), on, at: 90)
        #expect(fire(AlertSnapshot(ssdSMARTWarning: true), on, at: 120).isEmpty)
        _ = fire(AlertSnapshot(ssdSMARTWarning: false), on, at: 180)
        _ = fire(AlertSnapshot(ssdSMARTWarning: false), on, at: 241)
        #expect(fire(AlertSnapshot(ssdSMARTWarning: true), on, at: 250).isEmpty)
        #expect(fire(AlertSnapshot(ssdSMARTWarning: true), on, at: 1_801) == [.ssdHealth])
    }

    @Test mutating func vpnDropOnlyAfterPreviouslyObservedConnection() {
        let on = AlertSettings(vpnDisconnect: true)
        let online = AlertSnapshot(networkConnected: true)
        let vpn = AlertSnapshot(networkConnected: true, vpnConnected: true)
        #expect(fire(online, on, at: 0).isEmpty)  // startup without VPN is not a disconnect
        #expect(fire(online, on, at: 120).isEmpty)
        _ = fire(vpn, on, at: 130)
        #expect(fire(online, on, at: 131).isEmpty)
        _ = fire(vpn, on, at: 140)  // quick reconnect cancels the pending alert
        _ = fire(online, on, at: 150)
        #expect(fire(online, on, at: 164).isEmpty)
        #expect(fire(online, on, at: 165) == [.vpnDisconnect])
        #expect(fire(online, on, at: 200).isEmpty)
    }

    @Test mutating func vpnOfflineDoesNotCountAsOnlineExposure() {
        let on = AlertSettings(vpnDisconnect: true)
        let vpn = AlertSnapshot(networkConnected: true, vpnConnected: true)
        let offline = AlertSnapshot()
        let online = AlertSnapshot(networkConnected: true)
        _ = fire(vpn, on, at: 0)
        #expect(fire(offline, on, at: 5).isEmpty)
        #expect(fire(offline, on, at: 30).isEmpty)
        #expect(fire(online, on, at: 31).isEmpty)
        #expect(fire(online, on, at: 46) == [.vpnDisconnect])
    }

    @Test mutating func vpnRearmsOnlyAfterReconnectionAndCooldown() {
        let on = AlertSettings(vpnDisconnect: true)
        let vpn = AlertSnapshot(networkConnected: true, vpnConnected: true)
        let online = AlertSnapshot(networkConnected: true)
        _ = fire(vpn, on, at: 0)
        _ = fire(online, on, at: 1)
        #expect(fire(online, on, at: 16) == [.vpnDisconnect])
        _ = fire(vpn, on, at: 100)
        _ = fire(vpn, on, at: 161)
        _ = fire(online, on, at: 162)
        #expect(fire(online, on, at: 177).isEmpty)
        #expect(fire(online, on, at: 1_817) == [.vpnDisconnect])
    }

    @Test mutating func togglingVPNAlertOffForgetsPreviousTunnel() {
        let on = AlertSettings(vpnDisconnect: true)
        _ = fire(AlertSnapshot(networkConnected: true, vpnConnected: true), on, at: 0)
        _ = fire(AlertSnapshot(networkConnected: true), AlertSettings(), at: 1)
        #expect(fire(AlertSnapshot(networkConnected: true), on, at: 50).isEmpty)
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
        let bad = AlertSnapshot(
            batteryCharge: 0.01, onBattery: true, batteryTemperatureC: 45, ssdSMARTWarning: true,
            networkConnected: true, diskAvailable: 1, memoryPressure: .critical, cpu: 1)
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
