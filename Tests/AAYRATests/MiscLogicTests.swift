import Testing
@testable import AAYRA

/// Version comparison (update check) and naming rules (process list).
struct VersionTests {
    @Test(arguments: [
        ("1.4", "1.3", true),
        ("v1.4", "1.3", true),       // tags have a "v" prefix
        ("1.3", "1.3", false),
        ("1.3.0", "1.3", false),     // same version, different length
        ("1.3.1", "1.3", true),
        ("1.10", "1.9", true),       // numeric, not alphabetical
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
        #expect(AppSettings.Shortcut.optionCommandM.key?.code == 46)   // kVK_ANSI_M
        #expect(AppSettings.Shortcut.optionCommandM.title == "⌥⌘M")
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
