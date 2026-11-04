import Darwin
import Foundation

/// One process inside a group, e.g. "Code Helper (Plugin)" inside Visual Studio Code.
struct ProcessMember: Equatable, Identifiable {
    let id: pid_t
    let name: String
    let value: Double  // bytes of memory, or % CPU, matching the group it belongs to
}

/// Memory footprint per app or process (the "Memory" column in Activity Monitor).
struct ProcessMemory: Equatable, Identifiable {
    let id: String  // grouping key: the app bundle path, or the executable path
    let name: String
    let footprint: UInt64
    var count = 1  // processes added together under this name
    var members: [ProcessMember] = []  // those processes, largest first
}

/// CPU usage per app or process, as a percentage of one core (the "% CPU" column in Activity Monitor).
struct ProcessCPU: Equatable, Identifiable {
    let id: String
    let name: String
    let percent: Double
    var count = 1
    var members: [ProcessMember] = []  // busiest first
}

/// Walks the process list once per sample to rank apps and processes by memory and CPU.
/// Processes inside an app bundle (e.g. "Code Helper (Plugin)" inside Visual Studio Code.app) are
/// added together under the app's real name, so a browser with 30 helpers shows as one entry.
/// Only processes owned by the current user can be inspected (root daemons are skipped by macOS).
final class ProcessSampler {
    private struct Entry { let key: String; let processName: String; let footprint: UInt64; let cpuNanos: UInt64 }
    /// `name` is the group's (app's) name; `processName` is this executable's own name.
    private struct Identity { let key: String; let name: String; let processName: String }

    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private var identities: [String: Identity] = [:]  // executable path → group, cached
    private var names: [String: String] = [:]  // group key → display name
    private(set) var processCount = 0

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Returns the top apps and processes by memory, and by CPU since the previous call.
    func sample(top count: Int) -> (memory: [ProcessMemory], cpu: [ProcessCPU]) {
        let entries = readAll()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = previousTime > 0 ? now - previousTime : 0

        var footprints: [String: (bytes: UInt64, processes: Int)] = [:]
        var cpuPercent: [String: Double] = [:]
        var memoryMembers: [String: [ProcessMember]] = [:]
        var cpuMembers: [String: [ProcessMember]] = [:]
        var current: [pid_t: UInt64] = [:]
        for (pid, entry) in entries {
            footprints[entry.key, default: (0, 0)].bytes += entry.footprint
            footprints[entry.key, default: (0, 0)].processes += 1
            memoryMembers[entry.key, default: []]
                .append(ProcessMember(id: pid, name: entry.processName, value: Double(entry.footprint)))
            current[pid] = entry.cpuNanos
            var percent = 0.0
            if elapsed > 0, let before = previousCPU[pid], entry.cpuNanos > before {
                percent = Double(entry.cpuNanos - before) / Double(elapsed) * 100
                cpuPercent[entry.key, default: 0] += percent
            }
            cpuMembers[entry.key, default: []].append(ProcessMember(id: pid, name: entry.processName, value: percent))
        }
        previousCPU = current
        previousTime = now

        let memory =
            footprints
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(count)
            .map {
                ProcessMemory(
                    id: $0.key, name: names[$0.key] ?? $0.key, footprint: $0.value.bytes,
                    count: $0.value.processes,
                    members: (memoryMembers[$0.key] ?? []).sorted { $0.value > $1.value })
            }
        let cpu =
            cpuPercent
            .filter { $0.value >= 0.1 }
            .sorted { $0.value > $1.value }
            .prefix(count)
            .map {
                ProcessCPU(
                    id: $0.key, name: names[$0.key] ?? $0.key, percent: $0.value,
                    count: footprints[$0.key]?.processes ?? 1,
                    members: (cpuMembers[$0.key] ?? []).sorted { $0.value > $1.value })
            }
        return (Array(memory), Array(cpu))
    }

    private func readAll() -> [pid_t: Entry] {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        guard capacity > 32 else { return [:] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard found > 0 else { return [:] }
        processCount = found  // every process, including ones we can't inspect

        var result: [pid_t: Entry] = [:]
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)  // PROC_PIDPATHINFO_MAXSIZE
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(found) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }

            let identity: Identity
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                identity = self.identity(forExecutable: String(cString: pathBuffer))
            } else if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
                let name = String(cString: nameBuffer)
                identity = Identity(key: "name:" + name, name: name, processName: name)
            } else {
                continue
            }
            names[identity.key] = identity.name

            // CPU times are reported in mach absolute-time units on Apple Silicon.
            let ticks = info.ri_user_time + info.ri_system_time
            let nanos = ticks &* Self.timebase.numer / Self.timebase.denom
            result[pid] = Entry(
                key: identity.key, processName: identity.processName,
                footprint: info.ri_phys_footprint, cpuNanos: nanos)
        }
        return result
    }

    /// Groups an executable under its outermost app bundle, if it has one.
    private func identity(forExecutable path: String) -> Identity {
        if let cached = identities[path] { return cached }
        let identity: Identity
        let processName = Self.readableName(ofExecutable: path)
        if let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            identity = Identity(key: appPath, name: Self.displayName(ofApp: appPath), processName: processName)
        } else {
            identity = Identity(key: path, name: processName, processName: processName)
        }
        identities[path] = identity
        return identity
    }

    /// The name Finder shows for the app, e.g. "Visual Studio Code" (its bundle says just "Code").
    private static func displayName(ofApp path: String) -> String {
        let name = (FileManager.default.displayName(atPath: path) as NSString)
        return name.pathExtension == "app" ? name.deletingPathExtension : name as String
    }

    /// The executable's file name, except when that's just a version number
    /// (e.g. ".../claude/versions/2.1.318"): then the nearest meaningful folder name is used.
    static func readableName(ofExecutable path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return path }
        guard isVersionLike(last) else { return last }
        let skipped: Set<String> = ["versions", "bin", "current", "libexec", "lib"]
        for part in parts.dropLast().reversed() where !isVersionLike(part) && !skipped.contains(part.lowercased()) {
            return part
        }
        return last
    }

    static func isVersionLike(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
    }
}
