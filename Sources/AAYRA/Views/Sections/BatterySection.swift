import SwiftUI

// Battery: the card in the panel and its detail panel.

struct BatteryCard: View {
    let battery: BatteryStats
    var drainCause: BatteryDrainInsight.Cause?

    var body: some View {
        let tint = battery.tint, maxCapacity = battery.maxCapacity
        Card(symbol: battery.symbol, tint: tint) {
            MeterHeader(title: "Battery", value: Format.percent(battery.charge))
        } details: {
            StackedBar(
                segments: [
                    .init(value: battery.charge * maxCapacity, color: tint),
                    .init(value: (1 - battery.charge) * maxCapacity, color: .clear),
                    .init(value: 1 - maxCapacity, color: Palette.batteryWorn),
                ], height: 8)
            HStack(spacing: 10) {
                Text(stateText)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Stat(label: "Temp", value: battery.temperatureC.map(Format.temperature) ?? "—")
            }
            HStack(spacing: 10) {
                Stat(label: "Cycles", value: battery.cycleText)
                Spacer(minLength: 0)
                Stat(label: "Capacity", value: battery.capacityText)
            }
        }
    }

    /// The card adds the adapter wattage when plugged in, e.g. "Charging · 1h 10m · 96W adapter".
    private var stateText: String {
        let adapter = battery.adapterWatts.map { " · \($0)W adapter" } ?? ""
        let state = drainCause == nil ? battery.stateText : "Battery draining on AC"
        return state + (battery.isPluggedIn ? adapter : "")
    }
}

struct BatteryDetail: View {
    let battery: BatteryStats
    let lowPowerMode: Bool
    var drainCause: BatteryDrainInsight.Cause?

    var body: some View {
        DetailPanel(
            symbol: battery.symbol, tint: battery.tint, title: "Battery", subtitle: subtitle,
            actions: [
                DetailAction(title: "Battery Settings…", symbol: "gearshape") {
                    SystemActions.openSettings(.battery)
                }
            ]
        ) {
            chargeSection
            healthSection
            packSection
        } trailing: {
            powerSection
            lifetimeSection
        }
    }

    private var subtitle: String {
        "\(Format.percent(battery.charge)) · \(drainCause == nil ? battery.stateText : "Battery draining on AC")"
    }

    private var chargeSection: some View {
        DetailSection("Charge") {
            StackedBar(
                segments: [
                    .init(value: battery.charge * battery.maxCapacity, color: battery.tint),
                    .init(value: (1 - battery.charge) * battery.maxCapacity, color: .clear),
                    .init(value: 1 - battery.maxCapacity, color: Palette.batteryWorn),
                ], height: 8
            )
            .padding(.vertical, 3)
            DetailRow("Charge", Format.percent(battery.charge), dot: battery.tint)
            DetailRow("State", battery.stateText)
            if let t = battery.temperatureC { DetailRow("Temperature", Format.temperature(celsius: t)) }
            if let low = battery.dailyMinSoc, let high = battery.dailyMaxSoc {
                DetailRow("Today's range", "\(low)–\(high)%")
            }
        }
    }

    private var healthSection: some View {
        DetailSection("Health") {
            DetailRow("Max capacity", battery.health.map { Format.percent($0) } ?? "—", dot: battery.tint)
            DetailRow("Worn", Format.percent(1 - battery.maxCapacity), dot: Palette.batteryWorn)
            DetailRow("Condition", battery.condition ?? "—", dot: battery.conditionColor)
            DetailRow("Cycles", battery.cycleText)
            if let full = battery.fullChargeCapacity_mAh {
                DetailRow("Full charge", "\(full)" + (battery.designCapacity_mAh.map { " / \($0)" } ?? "") + " mAh")
            }
            if let remaining = battery.remaining_mAh, let max = battery.rawMax_mAh {
                DetailRow("Remaining", "\(remaining) / \(max) mAh")
            }
        }
    }

    private var packSection: some View {
        DetailSection("Pack") {
            if let date = battery.manufactureDate {
                let when = date.formatted(.dateTime.day().month(.abbreviated).year())
                DetailRow("Manufactured", battery.manufactureDateIsEstimate ? "≈ \(when)" : when)
                DetailRow("Age", (battery.manufactureDateIsEstimate ? "≈ " : "") + Format.age(since: date))
            }
            DetailRow("Assembled by", battery.packManufacturer ?? "Unknown")
            DetailRow("Cells by", battery.manufacturer ?? "Unknown")
            if let serial = battery.serial { DetailRow("Serial", serial, placeholder: "F8Y0000000000000A") }
        }
    }

    private var powerSection: some View {
        DetailSection("Power") {
            DetailRow("Battery", batteryFlow)
            if let drainCause {
                DetailRow("On AC", drainCause.title, dot: .orange)
                Text(drainCause.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let load = battery.systemLoadWatts { DetailRow("Mac drawing", String(format: "%.1f W", load)) }
            if let mV = battery.voltage_mV { DetailRow("Voltage", Format.volts(mV)) }
            if let mA = battery.current_mA { DetailRow("Current", "\(mA) mA") }
            if !battery.cellVoltages_mV.isEmpty {
                let cells = battery.cellVoltages_mV
                DetailRow("Cells", cells.map { String(format: "%.3f", Double($0) / 1000) }.joined(separator: " / ") + " V")
                DetailRow("Cell spread", "\((cells.max() ?? 0) - (cells.min() ?? 0)) mV")
            }
            DetailRow("Adapter", battery.adapterStatus)
            if let input = battery.adapterInputWatts { DetailRow("Adapter input", String(format: "%.1f W", input)) }
            DetailRow("Low Power Mode", Format.onOff(lowPowerMode))
        }
    }

    private var lifetimeSection: some View {
        DetailSection("Lifetime") {
            if let low = battery.lifetimeMinTempC, let high = battery.lifetimeMaxTempC {
                DetailRow(
                    "Temperature", "\(Format.temperature(celsius: Double(low))) – \(Format.temperature(celsius: Double(high)))")
            }
            if let avg = battery.lifetimeAvgTempC { DetailRow("Average temp", Format.temperature(celsius: avg)) }
            if let charge = battery.maxChargeCurrent_mA { DetailRow("Peak charge", Format.amps(charge)) }
            if let discharge = battery.maxDischargeCurrent_mA { DetailRow("Peak discharge", Format.amps(discharge)) }
            if let low = battery.minPackVoltage_mV, let high = battery.maxPackVoltage_mV {
                DetailRow("Pack voltage", "\(Format.volts(low)) – \(Format.volts(high))")
            }
            if let hours = battery.operatingHours {
                DetailRow("Operating time", "\(hours.formatted()) h (\(hours / 24) d)")
            }
            let faults = (battery.permanentFailure ?? 0) + (battery.cellDisconnects ?? 0)
            DetailRow("Faults", faults == 0 ? "None" : "Code \(battery.permanentFailure ?? 0)")
            if let limited = battery.thermallyLimitedCharging, limited > 0 {
                DetailRow("Heat-limited charging", "\(limited.formatted())×")
            }
        }
    }

    private var batteryFlow: String {
        guard let watts = battery.powerWatts, abs(watts) >= 0.05 else { return "Idle (0 W)" }
        let rate = String(format: "%.1f W", abs(watts))
        return watts < 0 ? "Discharging \(rate)" : "Charging \(rate)"
    }
}

extension BatteryStats {
    var maxCapacity: Double { min(max(health ?? 1, 0), 1) }

    var symbol: String {
        if state == .charging || state == .charged { return "battery.100percent.bolt" }
        switch charge {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Never red: a low battery isn't a fault.
    var tint: Color {
        if isPluggedIn { return Palette.battery }
        return charge <= 0.2 ? .orange : Palette.battery
    }

    /// State and time in one short phrase, e.g. "6h 35m left" or "Charging · 1h 10m".
    var stateText: String {
        switch state {
        case .onBattery: minutesToEmpty.map { "\(Format.minutes($0)) left" } ?? "Calculating…"
        case .charging: "Charging" + (minutesToFull.map { " · \(Format.minutes($0))" } ?? "")
        case .charged: "Charged"
        case .pluggedNotCharging: "Not Charging"
        }
    }

    var cycleText: String {
        guard let cycles = cycleCount else { return "—" }
        return designCycles.map { "\(cycles) / \($0)" } ?? "\(cycles)"
    }

    var capacityText: String {
        guard let now = currentCapacity_mAh, let design = designCapacity_mAh else { return "—" }
        return "\(now) / \(design) mAh"
    }

    var conditionColor: Color {
        switch condition?.lowercased() {
        case "good", "normal": .green
        case nil: .secondary
        default: .orange  // "Fair", "Service Recommended", …
        }
    }

    var adapterStatus: String {
        guard isPluggedIn else { return "Not connected" }
        let parts = [adapterWatts.map { "\($0)W" }, adapterName].compactMap { $0 }
        let detail: String =
            switch state {
            case .charging: "charging"
            case .charged: "full"
            case .pluggedNotCharging: "not charging"
            case .onBattery: ""
            }
        let text = parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
        return text + (detail.isEmpty ? "" : " (\(detail))")
    }
}
