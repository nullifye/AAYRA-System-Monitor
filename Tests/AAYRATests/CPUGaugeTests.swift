import AppKit
import Testing

@testable import AAYRA

@MainActor
struct CPUGaugeTests {
    @Test func disabledAnimationParksAt25AndEnabledAnimationUsesEveryCPUPercentage() {
        for percent in 0...100 {
            let fraction = Double(percent) / 100
            #expect(CPUGaugeFrames.target(for: fraction, animationEnabled: false) == 0.25)
            #expect(CPUGaugeFrames.target(for: fraction, animationEnabled: true) == fraction)
            #expect(abs(CPUGaugeFrames.needleAngle(fraction) - .pi * (1 - fraction)) < 0.0001)
        }
    }

    @Test func needleMapsCPUUsageAcrossUpperSemicircle() {
        let left = CPUGaugeFrames.needleTip(0)
        let middle = CPUGaugeFrames.needleTip(0.5)
        let right = CPUGaugeFrames.needleTip(1)
        #expect(left.x < 9 && abs(left.y - 5) < 0.0001)
        #expect(abs(middle.x - 9) < 0.0001 && middle.y > 5)
        #expect(right.x > 9 && abs(right.y - 5) < 0.0001)
        #expect(abs(CPUGaugeFrames.needleAngle(0.25) - .pi * 0.75) < 0.0001)
        #expect(abs(CPUGaugeFrames.needleAngle(0.75) - .pi * 0.25) < 0.0001)
        let tips = (0...100).map { CPUGaugeFrames.needleTip(Double($0) / 100) }
        #expect(zip(tips, tips.dropFirst()).allSatisfy { $0.x < $1.x })
    }

    @Test func invalidUsageIsClampedAndFramesRemainTemplates() {
        #expect(CPUGaugeFrames.normalized(-1) == 0)
        #expect(CPUGaugeFrames.normalized(2) == 1)
        #expect(CPUGaugeFrames.normalized(.nan) == 0)
        #expect(CPUGaugeFrames.normalized(.infinity) == 0)
        #expect(CPUGaugeFrames.frame(at: -1) === CPUGaugeFrames.frame(at: 0))
        #expect(CPUGaugeFrames.frame(at: 101) === CPUGaugeFrames.frame(at: 100))
        #expect(CPUGaugeFrames.frame(at: 50).isTemplate)
        #expect(CPUGaugeFrames.frame(at: 50).size.width > SpinnerFrames.size.width)
        #expect(CPUGaugeFrames.frame(at: 50).size.width <= 22)
    }

    @Test func existingInstallsKeepTurbineUntilAStyleIsChosen() {
        #expect(AppSettings.IconAnimationStyle.saved(nil) == .turbine)
        #expect(AppSettings.IconAnimationStyle.saved("unknown") == .turbine)
        #expect(AppSettings.IconAnimationStyle.saved("gauge") == .gauge)
        #expect(AppSettings.IconAnimationStyle.saved("turbine") == .turbine)
    }
}
