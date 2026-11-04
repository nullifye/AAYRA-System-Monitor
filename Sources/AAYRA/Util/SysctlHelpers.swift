import Darwin
import Foundation
import IOKit

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            // Some keys are 32-bit.
            var v32: Int32 = 0
            var s32 = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &v32, &s32, nil, 0) == 0 else { return nil }
            return Int(v32)
        }
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func value<T: BitwiseCopyable>(_ name: String, as type: T.Type, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

enum MachineInfo {
    /// Friendly marketing name, e.g. "MacBook Air (13-inch, M4, 2025)".
    static let productName: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let cf = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(),
           let data = cf as? Data {
            let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            if !name.isEmpty { return name }
        }
        return Sysctl.string("hw.model") ?? "Mac"
    }()

    static let chip: String = Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon"

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    static var bootDate: Date? {
        guard let tv = Sysctl.value("kern.boottime", as: timeval.self, initial: timeval()) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
