import Darwin

struct CPUStats: Equatable {
    var total: Double = 0      // 0...1
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
    var loadAverage: (Double, Double, Double) = (0, 0, 0)

    static func == (a: CPUStats, b: CPUStats) -> Bool {
        a.total == b.total && a.user == b.user && a.system == b.system && a.perCore == b.perCore
            && a.loadAverage == b.loadAverage
    }
}

/// Samples per-core CPU tick counters and reports usage since the previous sample.
final class CPUProvider {
    private struct Ticks { var user, system, idle, nice: UInt32 }
    private var previous: [Ticks] = []

    let performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
    let efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0

    func sample() -> CPUStats? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [Ticks] = []
        current.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            current.append(Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        var perCore: [Double] = []
        var sumUser = 0.0, sumSystem = 0.0, sumAll = 0.0
        for (now, before) in zip(current, previous) {
            // Wrapping subtraction handles 32-bit counter overflow.
            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let all = user + system + idle
            perCore.append(all > 0 ? (user + system) / all : 0)
            sumUser += user; sumSystem += system; sumAll += all
        }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        guard sumAll > 0 else { return nil }
        return CPUStats(
            total: (sumUser + sumSystem) / sumAll,
            user: sumUser / sumAll,
            system: sumSystem / sumAll,
            perCore: perCore,
            loadAverage: (loads[0], loads[1], loads[2])
        )
    }
}
