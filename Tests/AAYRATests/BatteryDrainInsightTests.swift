import Testing

@testable import AAYRA

struct BatteryDrainInsightTests {
    private func sample(
        state: BatteryStats.State = .pluggedNotCharging, watts: Double? = -6,
        rated: Int? = 30, load: Double? = 55
    ) -> BatteryStats {
        var battery = BatteryStats()
        battery.state = state
        battery.powerWatts = watts
        battery.adapterWatts = rated
        battery.systemLoadWatts = load
        return battery
    }

    @Test func sustainedDrainWithUndersizedAdapter() {
        var insight = BatteryDrainInsight()
        for time in stride(from: 0.0, through: 50.0, by: 10) {
            insight.update(sample(), at: time)
            #expect(insight.cause == nil)
        }
        insight.update(sample(), at: 60)
        #expect(insight.cause == .adapterMayBeUnderpowered)
    }

    @Test func unknownCauseWithoutStrongRatingEvidence() {
        var insight = BatteryDrainInsight()
        for time in stride(from: 0.0, through: 60.0, by: 10) {
            insight.update(sample(rated: 96, load: 55), at: time)
        }
        #expect(insight.cause == .unknown)
        insight.update(sample(rated: nil, load: nil), at: 70)
        #expect(insight.cause == .unknown)
    }

    @Test func transitionsAndSmallNegativeReadingsReset() {
        var insight = BatteryDrainInsight()
        for time in stride(from: 0.0, through: 60.0, by: 10) { insight.update(sample(), at: time) }
        insight.update(sample(watts: -0.5), at: 70)
        #expect(insight.cause == nil)
        insight.update(sample(), at: 80)
        insight.update(sample(state: .onBattery), at: 90)
        #expect(insight.cause == nil)
        insight.update(sample(state: .charging), at: 100)
        #expect(insight.cause == nil)
        insight.update(nil, at: 110)
        #expect(insight.cause == nil)
    }

    @Test func sleepingDoesNotCountTowardDuration() {
        var insight = BatteryDrainInsight()
        insight.update(sample(), at: 0)
        insight.update(sample(), at: 10)
        insight.update(sample(), at: 200)
        #expect(insight.cause == nil)
        for time in stride(from: 210.0, through: 260.0, by: 10) { insight.update(sample(), at: time) }
        #expect(insight.cause == .adapterMayBeUnderpowered)
    }

    @Test func transientLoadSpikeIsNotDiagnosedAsWeakAdapter() {
        var insight = BatteryDrainInsight()
        insight.update(sample(), at: 0)
        for time in stride(from: 10.0, through: 60.0, by: 10) {
            insight.update(sample(rated: 30, load: 20), at: time)
        }
        #expect(insight.cause == .unknown)
    }

    @Test func reasonTracksRecentReadingsRatherThanOldHighLoad() {
        var insight = BatteryDrainInsight()
        for time in stride(from: 0.0, through: 60.0, by: 10) { insight.update(sample(), at: time) }
        #expect(insight.cause == .adapterMayBeUnderpowered)
        insight.update(sample(rated: 96, load: 55), at: 70)
        #expect(insight.cause == .unknown)
    }
}
