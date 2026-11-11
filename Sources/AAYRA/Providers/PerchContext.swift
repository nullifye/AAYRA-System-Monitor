import Foundation

/// One Perch CLI thread's context snapshot, read from the thread file the CLI keeps on disk.
///
/// Perch keeps no per-request token ledger and exposes no readable quota, so this is context
/// *fill* — how much of the model's window a thread is using — not spend. Reading it costs
/// nothing: it is a file the CLI already wrote.
struct PerchThreadContext: Equatable, Identifiable, Sendable {
    let id: String
    /// The thread's last objective, used as a stand-in for a name.
    let objective: String?
    let model: String?
    let usedTokens: Int64
    let limitTokens: Int64
    /// The most recent turn's provider-reported usage, when the snapshot carries one.
    let lastTurn: TokenTally?
    let sections: [PerchSection]
    let updatedAt: Date

    /// Share of the context window in use, 0...100.
    var percent: Double {
        guard limitTokens > 0 else { return 0 }
        return min(100, max(0, Double(usedTokens) / Double(limitTokens) * 100))
    }

    var label: String { objective ?? String(id.prefix(18)) }
}

/// One slice of a thread's context, e.g. "System prompt" or "Tools".
struct PerchSection: Equatable, Identifiable, Sendable {
    let name: String
    let tokens: Int64
    var id: String { name }
}

/// Reads `~/.perch/threads`, where the Perch CLI writes one JSON snapshot per thread.
///
/// Only counts, model names and the thread's own objective are kept, in memory; message text is
/// never retained. A thread file the CLI has not written yet simply doesn't appear.
enum PerchContext {
    /// Scan budget: past this many thread files or bytes, report nothing rather than a partial list.
    private static let maxFiles = 60
    private static let maxBytes = 4_000_000

    /// Every thread snapshot on this Mac, newest first.
    static func threads(paths: AgentPaths = .init(), limit: Int = maxFiles) -> [PerchThreadContext] {
        let manager = FileManager.default
        let root = paths.perchThreads
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var files: [URL] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                let children = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                files += children.filter { $0.pathExtension == "json" }
            } else if entry.pathExtension == "json" {
                files.append(entry)
            }
        }
        var result: [PerchThreadContext] = []
        var bytes = 0
        for file in files.prefix(maxFiles) {
            guard
                let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                info.isRegularFile == true, let size = info.fileSize, size > 0, size <= maxBytes
            else { continue }
            bytes += size
            guard bytes <= maxBytes else { break }
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), let context = parse(data) else {
                continue
            }
            result.append(context)
        }
        return Array(result.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// One thread file. Returns nil for anything that isn't a version-1 thread with a usable snapshot.
    static func parse(_ data: Data) -> PerchThreadContext? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (root["version"] as? NSNumber)?.intValue == 1,
            let threadId = root["threadId"] as? String, !threadId.isEmpty, threadId.count < 256,
            let snapshot = root["contextSnapshot"] as? [String: Any]
        else { return nil }
        // Both figures must be present: a snapshot without a limit can't be turned into a share.
        guard let used = AgentLocalTokens.count(snapshot["totalContextTokens"]), used > 0,
            let limit = AgentLocalTokens.count(snapshot["contextLimitTokens"]), limit > 0
        else { return nil }
        let session = root["threadSession"] as? [String: Any]
        return PerchThreadContext(
            id: threadId,
            objective: objective(session?["lastObjective"] as? String),
            model: model(snapshot),
            usedTokens: used,
            limitTokens: limit,
            lastTurn: lastTurn(snapshot["turnApiUsage"]),
            sections: sections(snapshot),
            updatedAt: AgentLocalTokens.date(root["updatedAt"]) ?? Date(timeIntervalSince1970: 0))
    }

    /// "Standard" reads better than the provider's model id; fall back to the id when it is absent.
    private static func model(_ snapshot: [String: Any]) -> String? {
        for key in ["modelLabel", "modelId"] {
            guard let value = (snapshot[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty, value.count < 64
            else { continue }
            return value
        }
        return nil
    }

    /// A one-line thread name: whitespace collapsed, capped so a long prompt can't stretch the card.
    private static func objective(_ raw: String?) -> String? {
        guard let text = raw?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !text.isEmpty
        else { return nil }
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    /// The last turn's usage. Cache reads are reported apart from fresh input, as elsewhere.
    private static func lastTurn(_ value: Any?) -> TokenTally? {
        guard let usage = value as? [String: Any] else { return nil }
        let tally = TokenTally(
            input: AgentLocalTokens.count(usage["inputTokens"]) ?? 0,
            output: AgentLocalTokens.count(usage["outputTokens"]) ?? 0,
            cacheRead: AgentLocalTokens.count(usage["cacheReadInputTokens"]) ?? 0)
        return tally.total > 0 ? tally : nil
    }

    /// What the context is made of, largest first, from the snapshot's own categories.
    private static func sections(_ snapshot: [String: Any]) -> [PerchSection] {
        var result: [PerchSection] = []
        for entry in snapshot["contextCategories"] as? [[String: Any]] ?? [] {
            guard let label = entry["label"] as? String, !label.isEmpty, label.count < 60,
                let tokens = AgentLocalTokens.count(entry["tokens"]), tokens > 0
            else { continue }
            result.append(.init(name: label, tokens: tokens))
        }
        return result.sorted { $0.tokens > $1.tokens }
    }
}
