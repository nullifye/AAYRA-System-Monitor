import Foundation
import Testing
@testable import AAYRA

/// Decoding of the raw values the battery's fuel gauge reports.
struct BatteryParsingTests {
    /// Packs six ASCII characters little-endian into a UInt64, the way the gauge stores DDMMYY.
    private func gaugeValue(_ text: String) -> UInt64 {
        text.utf8.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    private func ymd(_ date: Date?) -> [Int]? {
        guard let date else { return nil }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return [c.year!, c.month!, c.day!]
    }

    @Test func manufactureDateDecodesDDMMYY() {
        #expect(gaugeValue("311023") == 0x3332_3031_3133)          // the documented example
        #expect(ymd(BatteryProvider.decodeManufactureDate(gaugeValue("311023"))) == [2023, 10, 31])
        #expect(ymd(BatteryProvider.decodeManufactureDate(gaugeValue("260125"))) == [2025, 1, 26])
    }

    @Test(arguments: [
        "321222",   // day 32 (what this Mac's pack actually reports, so AAYRA estimates instead)
        "311323",   // month 13
        "310223",   // 31 February
        "010109",   // 2009: before Apple Silicon packs, so not this format
        "010199",   // 2099: in the future
        "31AB23",   // not digits
    ])
    func manufactureDateRejectsInvalid(text: String) {
        #expect(BatteryProvider.decodeManufactureDate(gaugeValue(text)) == nil)
    }

    @Test func packAssemblerFromSerialPrefix() {
        #expect(BatteryProvider.packAssembler(fromSerial: "F8YHCH004AG0000G42") == "Sunwoda")
        #expect(BatteryProvider.packAssembler(fromSerial: "d86abc") == "Desay")     // case-insensitive
        #expect(BatteryProvider.packAssembler(fromSerial: "C32XYZ") == "Simplo")
        #expect(BatteryProvider.packAssembler(fromSerial: "ZZZ123") == nil)        // unknown: no guess
        #expect(BatteryProvider.packAssembler(fromSerial: "") == nil)
    }

    /// Manufacturer data: length-prefixed ASCII fields; the last all-letter field is the cell maker.
    private func mfgData(_ fields: [String], junk: [UInt8] = []) -> Data {
        var bytes = junk
        for field in fields { bytes.append(UInt8(field.utf8.count)); bytes.append(contentsOf: field.utf8) }
        bytes.append(0)
        return Data(bytes)
    }

    @Test func cellManufacturerFromManufacturerData() {
        #expect(BatteryProvider.cellManufacturer(from: mfgData(["1234", "ATL"])) == "ATL (Amperex)")
        #expect(BatteryProvider.cellManufacturer(from: mfgData(["SWD", "0042"])) == "Sunwoda")  // last *letters* field
        #expect(BatteryProvider.cellManufacturer(from: mfgData(["QQX"])) == "QQX")             // unknown code kept as is
        #expect(BatteryProvider.cellManufacturer(from: mfgData(["ATL"], junk: [0xFF, 0x01])) == "ATL (Amperex)")
        #expect(BatteryProvider.cellManufacturer(from: mfgData(["1234", "5678"])) == nil)
        #expect(BatteryProvider.cellManufacturer(from: Data()) == nil)
    }

    @Test func stateAndCycleText() {
        var battery = BatteryStats()
        battery.state = .onBattery
        battery.minutesToEmpty = 395
        #expect(battery.stateText == "6h 35m left")
        battery.minutesToEmpty = nil
        #expect(battery.stateText == "Calculating…")
        battery.state = .charging
        battery.minutesToFull = 70
        #expect(battery.stateText == "Charging · 1h 10m")

        battery.cycleCount = 178
        battery.designCycles = 1000
        #expect(battery.cycleText == "178 / 1000")
        battery.cycleCount = nil
        #expect(battery.cycleText == "—")
    }
}
