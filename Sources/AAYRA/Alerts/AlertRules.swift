import Foundation

/// The alerts a user can turn on in Settings → Alerts.
enum AlertKind: String, CaseIterable {
    case batteryLow, batteryDrain, diskFull, memoryPressure, cpuBusy
}

/// Which alerts are on and their thresholds (all off by default).
struct AlertSettings: Equatable {
    var batteryLow = false
    var batteryDrain = false
    var batteryThreshold = 20  // percent
    var diskFull = false
    var diskThresholdGB = 10  // GB available on the startup disk
    var memoryPressure = false
    var memoryCriticalOnly = false  // false: alert at "high" pressure; true: only at "critical"
    var cpuBusy = false
    var cpuMinutes = 5  // minutes above 90 %

    func isOn(_ kind: AlertKind) -> Bool {
        switch kind {
        case .batteryLow: batteryLow
        case .batteryDrain: batteryDrain
        case .diskFull: diskFull
        case .memoryPressure: memoryPressure
        case .cpuBusy: cpuBusy
        }
    }
}

/// The readings the rules look at, taken from one monitor tick.
struct AlertSnapshot: Equatable {
    var batteryCharge: Double?  // 0…1, nil on Macs without a battery
    var onBattery = false
    var batteryDrainCause: BatteryDrainInsight.Cause?
    var diskAvailable: Int64 = .max  // bytes free (including purgeable) on the startup disk
    var memoryPressure: MemoryStats.Pressure = .normal
    var cpu: Double = 0  // 0…1
}

/// Decides when each alert fires. Pure logic (no notifications, no clock), so it can be tested.
///
/// Every alert fires once when its condition is met, then re-arms only after things are clearly back
/// to normal (hysteresis), so a value hovering around the threshold doesn't produce a stream of alerts.
/// Memory and CPU must also stay in that state for a while, and repeat at most every 30 minutes.
struct AlertRules {
    static let cpuBusyLevel = 0.90  // "pegged" starts here…
    static let cpuCalmLevel = 0.75  // …and only ends once usage drops below this
    static let memorySustain: TimeInterval = 60  // pressure must last a minute before alerting
    static let calmSustain: TimeInterval = 60  // and be gone a minute before re-arming
    static let repeatAfter: TimeInterval = 30 * 60
    static let batteryRearmMargin = 5.0  // percentage points above the threshold
    static let diskRearmFactor = 1.25  // 25 % more space than the threshold

    private var armed = Set(AlertKind.allCases)
    private var conditionSince: [AlertKind: TimeInterval] = [:]
    private var calmSince: [AlertKind: TimeInterval] = [:]
    private var lastFired: [AlertKind: TimeInterval] = [:]

    /// Returns the alerts that should be shown now. `now` is any monotonic time in seconds.
    mutating func evaluate(_ s: AlertSnapshot, settings: AlertSettings, now: TimeInterval) -> [AlertKind] {
        var fired: [AlertKind] = []
        for kind in AlertKind.allCases {
            guard settings.isOn(kind) else {
                reset(kind)  // turning an alert off and on again starts fresh
                continue
            }
            if update(kind, s, settings, now) { fired.append(kind) }
        }
        return fired
    }

    private mutating func update(_ kind: AlertKind, _ s: AlertSnapshot, _ settings: AlertSettings, _ now: TimeInterval)
        -> Bool
    {
        switch kind {
        case .batteryLow:
            guard let charge = s.batteryCharge else { return false }
            let percent = charge * 100, threshold = Double(settings.batteryThreshold)
            if !s.onBattery || percent > threshold + Self.batteryRearmMargin { armed.insert(kind) }
            return fireIfArmed(kind, when: s.onBattery && percent <= threshold, now: now)

        case .batteryDrain:
            // The insight already requires a minute of readings. Re-arm only after a calm
            // minute and limit repeats to once per 30 minutes if the problem returns.
            let active = s.batteryDrainCause != nil
            return sustained(kind, active: active, calm: !active, after: 0, now: now)

        case .diskFull:
            let threshold = Double(settings.diskThresholdGB) * 1_000_000_000
            if Double(s.diskAvailable) > threshold * Self.diskRearmFactor { armed.insert(kind) }
            return fireIfArmed(kind, when: Double(s.diskAvailable) < threshold, now: now)

        case .memoryPressure:
            let level: MemoryStats.Pressure = settings.memoryCriticalOnly ? .critical : .warning
            let high = Self.rank(s.memoryPressure) >= Self.rank(level)
            return sustained(kind, active: high, calm: !high, after: Self.memorySustain, now: now)

        case .cpuBusy:
            // Busy starts at 90 % and continues until usage falls below 75 %, so normal
            // fluctuation (95 %, 86 %, 98 %…) doesn't restart the clock.
            let busy = s.cpu >= Self.cpuBusyLevel || (conditionSince[kind] != nil && s.cpu >= Self.cpuCalmLevel)
            return sustained(
                kind, active: busy, calm: s.cpu < Self.cpuCalmLevel,
                after: TimeInterval(settings.cpuMinutes * 60), now: now)
        }
    }

    /// Battery and disk: fire as soon as the condition holds, once per arming.
    private mutating func fireIfArmed(_ kind: AlertKind, when condition: Bool, now: TimeInterval) -> Bool {
        guard condition, armed.contains(kind) else { return false }
        armed.remove(kind)
        lastFired[kind] = now
        return true
    }

    /// Memory and CPU: fire once the condition has lasted `after` seconds; re-arm after a calm minute.
    private mutating func sustained(
        _ kind: AlertKind, active: Bool, calm: Bool, after duration: TimeInterval, now: TimeInterval
    ) -> Bool {
        if active {
            if conditionSince[kind] == nil { conditionSince[kind] = now }
            calmSince[kind] = nil
        } else {
            conditionSince[kind] = nil
        }
        if calm {
            if calmSince[kind] == nil { calmSince[kind] = now }
            if now - (calmSince[kind] ?? now) >= Self.calmSustain { armed.insert(kind) }
        }
        guard active, armed.contains(kind), let since = conditionSince[kind], now - since >= duration,
            now - (lastFired[kind] ?? -.infinity) >= Self.repeatAfter
        else { return false }
        armed.remove(kind)
        lastFired[kind] = now
        return true
    }

    private mutating func reset(_ kind: AlertKind) {
        armed.insert(kind)
        conditionSince[kind] = nil
        calmSince[kind] = nil
        lastFired[kind] = nil
    }

    static func rank(_ pressure: MemoryStats.Pressure) -> Int {
        switch pressure {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}
