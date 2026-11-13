import AppKit
import Testing

@testable import AAYRA

/// Version comparison (update check) and naming rules (process list).
struct VersionTests {
    @Test(arguments: [
        ("1.4", "1.3", true),
        ("v1.4", "1.3", true),  // tags have a "v" prefix
        ("1.3", "1.3", false),
        ("1.3.0", "1.3", false),  // same version, different length
        ("1.3.1", "1.3", true),
        ("1.10", "1.9", true),  // numeric, not alphabetical
        ("1.2.9", "1.3", false),
        ("2.0", "1.99", true),
    ])
    func isNewer(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isVersion(candidate, newerThan: current) == expected)
    }
}

struct ProcessNamingTests {
    @Test func versionNumberedExecutablesUseTheirFolderName() {
        // Command-line tools installed as ".../<tool>/versions/<version>" show the tool's name.
        #expect(ProcessSampler.readableName(ofExecutable: "/Users/x/.local/share/claude/versions/2.1.318") == "claude")
        #expect(ProcessSampler.readableName(ofExecutable: "/opt/tool/1.2/bin/3.4") == "tool")
    }

    @Test func ordinaryExecutablesKeepTheirName() {
        #expect(ProcessSampler.readableName(ofExecutable: "/bin/zsh") == "zsh")
        #expect(ProcessSampler.readableName(ofExecutable: "/usr/local/bin/node") == "node")
    }

    @Test func versionLikeNames() {
        #expect(ProcessSampler.isVersionLike("2.1.318"))
        #expect(ProcessSampler.isVersionLike("42"))
        #expect(!ProcessSampler.isVersionLike("v2"))
        #expect(!ProcessSampler.isVersionLike(""))
    }
}

struct NetworkTests {
    @Test(arguments: [(-45, "Excellent"), (-55, "Good"), (-65, "Fair"), (-80, "Weak")])
    func wifiSignalQuality(rssi: Int, expected: String) {
        var wifi = WiFiDetails()
        wifi.rssi = rssi
        #expect(wifi.signalQuality == expected)
    }

    @Test func noSignalNoQuality() {
        #expect(WiFiDetails().signalQuality == nil)
    }
}

struct ShortcutTests {
    @Test func everyChoiceExceptOffHasAKey() {
        for shortcut in AppSettings.Shortcut.allCases {
            #expect((shortcut.key == nil) == (shortcut == .off))
        }
        #expect(AppSettings.Shortcut.optionCommandM.key?.code == 46)  // kVK_ANSI_M
        #expect(AppSettings.Shortcut.optionCommandM.title == "⌥⌘M")
    }
}

@MainActor
struct StatusItemLabelTests {
    @Test func agentPercentColorsUseWarningBoundaries() {
        #expect(AgentMenuBarText.percentageColor(0) == AgentMenuBarText.criticalColor)
        #expect(AgentMenuBarText.percentageColor(10) == AgentMenuBarText.criticalColor)
        #expect(AgentMenuBarText.percentageColor(10.01) == AgentMenuBarText.warningColor)
        #expect(AgentMenuBarText.percentageColor(30) == AgentMenuBarText.warningColor)
        #expect(AgentMenuBarText.percentageColor(30.01) == .white)
    }

    @Test func agentMenuBarColorsOnlyPercentagesAndKeepsShortNames() {
        let title = AgentMenuBarText.make([
            .init(name: AgentTool.claude.menuBarName, percent: 10),
            .init(name: AgentTool.codex.menuBarName, percent: 30), .init(name: "Copilot", percent: nil),
        ])
        #expect(title.string == "Claude 10% · Codex 30% · Copilot —")
        let string = title.string as NSString
        for (text, color) in [
            ("Claude", NSColor.labelColor), ("10%", AgentMenuBarText.criticalColor),
            ("30%", AgentMenuBarText.warningColor), ("—", .white),
        ] {
            let actual = title.attribute(.foregroundColor, at: string.range(of: text).location, effectiveRange: nil) as? NSColor
            #expect(actual == color)
        }
        #expect(AgentMenuBarText.make([]).length == 0)
    }

    @Test func contextUsageWarnsAtHighPercentages() {
        for (percent, expected) in [
            (0.0, NSColor.white), (10, .white), (69.99, .white),
            (70, AgentMenuBarText.warningColor), (89.99, AgentMenuBarText.warningColor),
            (90, AgentMenuBarText.criticalColor), (100, AgentMenuBarText.criticalColor),
        ] {
            let entry = AgentMenuBarText.Entry(name: "Perch", percent: percent, reportsUsage: true)
            #expect(entry.color == expected)
            let title = AgentMenuBarText.make([entry])
            let actual = title.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor
            #expect(actual == expected)
        }
        #expect(AgentMenuBarText.Entry(name: "Perch", percent: nil, reportsUsage: true).color == .white)
    }

    @Test func agentWarningColorsHaveReadableContrastInBothAppearances() throws {
        func luminance(_ color: NSColor) throws -> Double {
            let rgb = try #require(color.usingColorSpace(.sRGB))
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var resolved: [NSColor] = []
            appearance.performAsCurrentDrawingAppearance {
                resolved = [AgentMenuBarText.warningColor, AgentMenuBarText.criticalColor].compactMap {
                    $0.usingColorSpace(.sRGB)
                }
            }
            #expect(resolved.count == 2)
            let background = name == .darkAqua ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white
            let backgroundLuminance = try luminance(background)
            for color in resolved {
                #expect(color.alphaComponent == 1)
                let foregroundLuminance = try luminance(color)
                let contrast =
                    (max(foregroundLuminance, backgroundLuminance) + 0.05)
                    / (min(foregroundLuminance, backgroundLuminance) + 0.05)
                #expect(contrast >= 4.5)
            }
        }
    }

    @Test func cpuLabelHasConstantWidthFromOneToThreeDigits() {
        let titles = [0, 9, 10, 99, 100].map(StatusItemController.cpuTitle)
        #expect(titles.allSatisfy { $0.count == 5 })
        #expect(titles[1] == " 9%  ")
        #expect(titles[2] == " 10% ")
        #expect(titles[4] == " 100%")
    }
}

/// The big headline numbers split into a number and a smaller unit.
@MainActor
struct BigValueTests {
    @Test func splitsNumberAndUnit() {
        let storage = BigValue("40.8 GB", suffix: "free")
        #expect(storage.number == "40.8")
        #expect(storage.unit == "GB free")

        let percent = BigValue("24%")
        #expect(percent.number == "24")
        #expect(percent.unit == "%")

        let plain = BigValue("7")
        #expect(plain.number == "7")
        #expect(plain.unit == nil)
    }
}
