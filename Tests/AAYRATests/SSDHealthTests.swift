import Testing

@testable import AAYRA

struct SSDHealthTests {
    private func health(
        remaining: Double = 0.9, warning: Bool = false, errors: UInt64 = 0,
        spare: Int = 80, threshold: Int = 10
    ) -> SSDHealth {
        SSDHealth(
            health: remaining, temperatureC: nil, bytesWritten: 0, bytesRead: 0,
            powerOnHours: 0, powerCycles: 0, unsafeShutdowns: 0, mediaErrors: errors,
            availableSpare: spare, availableSpareThreshold: threshold, info: SSDInfo(),
            hasCriticalWarning: warning)
    }

    @Test func onlySMARTFaultsTriggerTheAlert() {
        #expect(!health().hasSMARTWarning)
        #expect(!health(remaining: 0.4).hasSMARTWarning)  // ordinary wear isn't a SMART failure
        #expect(health(warning: true).hasSMARTWarning)
        #expect(health(errors: 1).hasSMARTWarning)
        #expect(health(spare: 10).hasSMARTWarning)
        #expect(health(spare: 9).condition == "Check Drive")
        #expect(!health(spare: 0, threshold: 0).hasSMARTWarning)  // no published threshold
    }
}
