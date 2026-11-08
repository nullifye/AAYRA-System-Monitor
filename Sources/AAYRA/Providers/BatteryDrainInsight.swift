import Foundation

/// A cautious explanation of sustained battery use while macOS reports AC power.
/// Read-only: no charging or adapter settings are changed.
struct BatteryDrainInsight: Equatable {
    enum Cause: Equatable {
        case adapterMayBeUnderpowered
        case unknown

        var title: String {
            switch self {
            case .adapterMayBeUnderpowered: "Adapter may be underpowered"
            case .unknown: "Cause unknown"
            }
        }

        var explanation: String {
            switch self {
            case .adapterMayBeUnderpowered:
                "The Mac's reported power use is higher than the adapter's rated wattage. A higher-wattage charger may help."
            case .unknown:
                "The battery is supplying power while AC is connected. This can be temporary (including macOS battery maintenance); check the adapter and current workload if it continues."
            }
        }
    }

    private(set) var cause: Cause?
    private var startedAt: TimeInterval?
    private var lastSampleAt: TimeInterval?
    /// Recent evidence only, so an old high-load period cannot explain today's drain.
    private var recentUnderpowered: [Bool] = []

    /// Battery readings arrive about every 10 seconds; don't flag brief transitions.
    static let sustainedFor: TimeInterval = 60
    static let maximumSampleGap: TimeInterval = 25
    static let minimumDischargeWatts = 2.0

    mutating func update(_ battery: BatteryStats?, at time: TimeInterval) {
        guard let battery, battery.isPluggedIn, battery.state != .charging,
            let watts = battery.powerWatts, watts.isFinite, watts <= -Self.minimumDischargeWatts
        else {
            reset()
            return
        }
        if let lastSampleAt, time <= lastSampleAt || time - lastSampleAt > Self.maximumSampleGap {
            reset()  // Never count time asleep or an interrupted monitoring loop as sustained discharge.
        }
        startedAt = startedAt ?? time
        lastSampleAt = time
        let underpowered: Bool
        if let rated = battery.adapterWatts, rated > 0, let load = battery.systemLoadWatts, load.isFinite {
            underpowered = load > Double(rated) + 5
        } else {
            underpowered = false
        }
        recentUnderpowered.append(underpowered)
        if recentUnderpowered.count > 7 { recentUnderpowered.removeFirst() }

        guard let startedAt, time - startedAt >= Self.sustainedFor, recentUnderpowered.count >= 3 else { return }
        // A single load spike isn't evidence that the adapter's rating is insufficient.
        let matching = recentUnderpowered.filter { $0 }.count
        cause =
            underpowered && matching >= 3 && matching * 2 >= recentUnderpowered.count
            ? .adapterMayBeUnderpowered : .unknown
    }

    private mutating func reset() {
        cause = nil
        startedAt = nil
        lastSampleAt = nil
        recentUnderpowered.removeAll()
    }
}
