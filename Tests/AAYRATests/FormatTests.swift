import Testing
@testable import AAYRA

/// Formatters used across the cards and detail panels. Only formats that don't depend on the
/// Mac's language or region are pinned here, so the results are the same on CI and any Mac.
struct FormatTests {
    @Test(arguments: [
        (Int64(0), "0 B"),
        (999, "999 B"),
        (1_500, "1.5 KB"),
        (2_730_000_000, "2.7 GB"),
        (204_670_000_000, "205 GB"),          // three digits: no decimal
        (1_200_000_000_000, "1.2 TB"),
        (-5, "0 B"),                          // never negative
    ])
    func diskShort(bytes: Int64, expected: String) {
        #expect(Format.diskShort(bytes) == expected)
    }

    @Test func memoryShortUsesBinaryUnits() {
        #expect(Format.memoryShort(UInt64(512) * 1_048_576) == "512 MB")
        #expect(Format.memoryShort(UInt64(6.46 * 1_073_741_824)) == "6.5 GB")
        #expect(Format.memoryShort(UInt64(150) * 1_073_741_824) == "150 GB")
    }

    @Test(arguments: [
        (830.0, "830 B/s"),
        (45_000, "45 KB/s"),
        (1_200_000, "1.2 MB/s"),
        (12_400_000, "12.4 MB/s"),
        (20_000_000_000, "20.0 GB/s"),
        (-1, "0 B/s"),
    ])
    func compactRate(bytesPerSecond: Double, expected: String) {
        #expect(Format.compactRate(bytesPerSecond) == expected)
    }

    @Test func chartSpan() {
        #expect(Format.span(60) == "1 min")
        #expect(Format.span(120) == "2 min")
        #expect(Format.span(300) == "5 min")
        #expect(Format.span(90) == "90 s")
    }

    @Test func minutes() {
        #expect(Format.minutes(395) == "6h 35m")
        #expect(Format.minutes(60) == "1h 0m")
        #expect(Format.minutes(45) == "45m")
    }

    @Test func electrical() {
        #expect(Format.volts(12_460) == "12.46 V")
        #expect(Format.amps(-990) == "0.99 A")      // direction is shown elsewhere
        #expect(Format.amps(5_300) == "5.30 A")
        #expect(Format.onOff(true) == "On")
        #expect(Format.onOff(false) == "Off")
    }
}
