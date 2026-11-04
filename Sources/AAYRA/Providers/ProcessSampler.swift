import Darwin
import Foundation

/// Memory footprint per process (the "Memory" column in Activity Monitor).
struct ProcessMemory: Equatable {
    let name: String
    let footprint: UInt64
}

/// CPU usage per process, as a percentage of one core (the "% CPU" column in Activity Monitor).
struct ProcessCPU: Equatable {
    let name: String
    let percent: Double
}

/// Walks the process list once per sample to rank processes by memory and CPU.
/// Only processes owned by the current user can be inspected (root daemons are skipped by macOS).
final class ProcessSampler {
    private struct Entry { let name: String; let footprint: UInt64; let cpuNanos: UInt64 }

    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private(set) var processCount = 0

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Returns the top processes by memory and by CPU since the previous call.
    func sample(top count: Int) -> (memory: [ProcessMemory], cpu: [ProcessCPU]) {
        let entries = readAll()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = previousTime > 0 ? now - previousTime : 0

        var cpu: [ProcessCPU] = []
        var current: [pid_t: UInt64] = [:]
        for (pid, entry) in entries {
            current[pid] = entry.cpuNanos
            if elapsed > 0, let before = previousCPU[pid], entry.cpuNanos > before {
                let percent = Double(entry.cpuNanos - before) / Double(elapsed) * 100
                if percent >= 0.1 { cpu.append(ProcessCPU(name: entry.name, percent: percent)) }
            }
        }
        previousCPU = current
        previousTime = now

        let memory = entries.values
            .sorted { $0.footprint > $1.footprint }
            .prefix(count)
            .map { ProcessMemory(name: $0.name, footprint: $0.footprint) }
        return (Array(memory), Array(cpu.sorted { $0.percent > $1.percent }.prefix(count)))
    }

    private func readAll() -> [pid_t: Entry] {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        guard capacity > 32 else { return [:] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard found > 0 else { return [:] }
        processCount = found   // every process, including ones we can't inspect

        var result: [pid_t: Entry] = [:]
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(found) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0, proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            // CPU times are reported in mach absolute-time units on Apple Silicon.
            let ticks = info.ri_user_time + info.ri_system_time
            let nanos = ticks &* Self.timebase.numer / Self.timebase.denom
            result[pid] = Entry(name: String(cString: nameBuffer), footprint: info.ri_phys_footprint, cpuNanos: nanos)
        }
        return result
    }
}
