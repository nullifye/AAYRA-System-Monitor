import Foundation

struct AgentAllowance: Equatable, Identifiable, Codable, Sendable {
    let name: String
    let remaining: String
    let resetsAt: Date
    /// A server-reported allowance (or a percentage derived from its reported counts), never local token spend.
    let remainingPercent: Double?
    var id: String { name }

    init(name: String, remaining: String, resetsAt: Date, remainingPercent: Double? = nil) {
        self.name = name
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.remainingPercent = remainingPercent
    }
}

/// An account detail that isn't a resetting allowance, e.g. the plan or a credit balance.
struct AgentFact: Equatable, Identifiable, Codable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

struct AgentUsageStatus: Equatable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case claude = "Claude"
        case codex = "Codex"
        case copilot = "GitHub Copilot"
        case openCode = "OpenCode"
    }
    let kind: Kind
    let allowances: [AgentAllowance]
    let detail: String
    let checkedAt: Date?
    /// Shown in the detail panel only, so the cards keep their height.
    var facts: [AgentFact] = []
    var id: Kind { kind }

    static func unavailable(_ kind: Kind, _ reason: String) -> Self {
        .init(kind: kind, allowances: [], detail: reason, checkedAt: nil)
    }
}

enum AgentUsageProvider {
    /// Reads a recent Codex session file locally; only rate-limit events are parsed into results.
    static func codex(now: Date = Date(), directory: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentUsageStatus {
        let root = directory.appendingPathComponent(".codex/sessions", isDirectory: true)
        guard
            let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return .unavailable(.codex, "No local Codex sessions found") }
        var newest: (url: URL, date: Date)?
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true, let date = values.contentModificationDate,
                now.timeIntervalSince(date) < 900
            else { continue }
            if newest == nil || date > newest!.date { newest = (file, date) }
        }
        guard let file = newest?.url, let handle = try? FileHandle(forReadingFrom: file) else {
            return .unavailable(.codex, "No recent rate-limit snapshot; start a Codex session")
        }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length > 1_000_000 ? length - 1_000_000 : 0)
        let data = handle.readDataToEndOfFile()
        let allowances = parseCodex(data, now: now)
        return allowances.isEmpty
            ? .unavailable(.codex, "Recent session has no valid allowance data")
            : .init(
                kind: .codex, allowances: allowances, detail: "Local Codex snapshot · may lag account usage",
                checkedAt: newest?.date)
    }

    static func parseCodex(_ data: Data, now: Date) -> [AgentAllowance] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() where line.contains("rate_limits") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                object["type"] as? String == "event_msg",
                let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                let limits = payload["rate_limits"] as? [String: Any],
                let stamp = object["timestamp"] as? String,
                let observed = codexTimestamp(stamp),
                abs(now.timeIntervalSince(observed)) < 900
            else { continue }
            let windows = ["primary", "secondary"].compactMap { key -> AgentAllowance? in
                guard let meter = limits[key] as? [String: Any],
                    let used = (meter["used_percent"] as? NSNumber)?.doubleValue, used.isFinite, (0...100).contains(used),
                    let minutes = (meter["window_minutes"] as? NSNumber)?.intValue, minutes > 0,
                    let reset = (meter["resets_at"] as? NSNumber)?.doubleValue,
                    reset > now.timeIntervalSince1970, reset < now.timeIntervalSince1970 + 35 * 86_400
                else { return nil }
                let label = minutes == 300 ? "5-hour" : minutes == 10_080 ? "Weekly" : "\(minutes)-minute"
                return .init(
                    name: label, remaining: "\(Int((100 - used).rounded()))% remaining",
                    resetsAt: Date(timeIntervalSince1970: reset), remainingPercent: 100 - used)
            }
            if !windows.isEmpty { return windows }
        }
        return []
    }

    private static func codexTimestamp(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func openCode(now: Date = Date()) -> AgentUsageStatus {
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "/usr/bin/opencode"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .unavailable(.openCode, "OpenCode CLI not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["api", "get", "/api/experimental/usage/limits"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable(.openCode, "Could not reach OpenCode") }
        // The CLI uses its own authenticated service connection. Never read its credential store.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .unavailable(.openCode, "OpenCode allowance request failed") }
        let allowances = parseOpenCode(data, now: now)
        return allowances.isEmpty
            ? .unavailable(.openCode, "No account allowance reported by OpenCode")
            : .init(kind: .openCode, allowances: allowances, detail: "OpenCode account limits · experimental API", checkedAt: now)
    }

    static func parseOpenCode(_ data: Data, now: Date) -> [AgentAllowance] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = object["data"] as? [String: Any]
        else { return [] }
        var result: [AgentAllowance] = []
        if let go = account["go"] as? [String: Any] {
            for (key, label) in [("rolling", "Rolling"), ("weekly", "Weekly"), ("monthly", "Monthly")] {
                guard let meter = go[key] as? [String: Any], meter["limited"] as? Bool == true,
                    let used = (meter["percent"] as? NSNumber)?.doubleValue, used.isFinite, (0...100).contains(used),
                    let reset = (meter["resetsAt"] as? NSNumber)?.doubleValue,
                    reset / 1000 > now.timeIntervalSince1970
                else { continue }
                result.append(
                    .init(
                        name: label, remaining: "\(Int((100 - used).rounded()))% remaining",
                        resetsAt: Date(timeIntervalSince1970: reset / 1000), remainingPercent: 100 - used))
            }
        }
        if let budgets = account["budgets"] as? [[String: Any]] {
            for budget in budgets {
                guard let limit = (budget["limit"] as? NSNumber)?.doubleValue, limit > 0,
                    let spent = (budget["spent"] as? NSNumber)?.doubleValue, spent.isFinite,
                    let reset = (budget["resetsAt"] as? NSNumber)?.doubleValue,
                    reset / 1000 > now.timeIntervalSince1970
                else { continue }
                let name = budget["id"] as? String ?? "Budget"
                result.append(
                    .init(
                        name: name, remaining: String(format: "$%.2f of $%.2f remaining", max(0, limit - spent), limit),
                        resetsAt: Date(timeIntervalSince1970: reset / 1000),
                        remainingPercent: min(100, max(0, (limit - spent) / limit * 100))))
            }
        }
        return result
    }
}
