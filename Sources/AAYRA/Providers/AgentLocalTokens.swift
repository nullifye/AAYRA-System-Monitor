import Foundation
import SQLite3

/// Tokens by type. The buckets never overlap (cached input is not also counted as input, reasoning is
/// not also counted as output), so `total` counts every token exactly once.
struct TokenTally: Equatable, Sendable {
    /// Fresh, uncached input.
    var input: Int64 = 0
    /// Visible output (reasoning excluded).
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    /// For tools that only report a total.
    var unclassified: Int64 = 0

    var total: Int64 { input + output + reasoning + cacheRead + cacheWrite + unclassified }

    static func + (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
        TokenTally(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output, reasoning: lhs.reasoning + rhs.reasoning,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            unclassified: lhs.unclassified + rhs.unclassified)
    }
}

/// Locally observed token counts for *today*, by model, separate from account allowance.
/// Only usage metadata (counts, model names, times) is retained; session text and credentials never
/// leave this reader.
struct AgentTokenUsage: Equatable, Sendable {
    var byModel: [String: TokenTally] = [:]
    /// Tokens per working folder (full path), for agents that record one. Kept in memory only.
    var byProject: [String: Int64] = [:]

    var total: Int64 { byModel.values.reduce(0) { $0 + $1.total } }
    /// All models together.
    var tally: TokenTally { byModel.values.reduce(TokenTally(), +) }

    mutating func add(_ tally: TokenTally, model: String?, project: String? = nil) {
        guard tally.total > 0 else { return }
        let name = Self.modelName(model)
        byModel[name] = (byModel[name] ?? TokenTally()) + tally
        if let folder = Self.projectPath(project) { byProject[folder, default: 0] += tally.total }
    }

    static func + (lhs: AgentTokenUsage, rhs: AgentTokenUsage) -> AgentTokenUsage {
        var result = lhs
        for (model, tally) in rhs.byModel { result.byModel[model] = (result.byModel[model] ?? TokenTally()) + tally }
        for (project, tokens) in rhs.byProject { result.byProject[project, default: 0] += tokens }
        return result
    }

    /// An absolute folder path from a path or `file://` URL, without a trailing slash; nil if there is none.
    static func projectPath(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? "") : raw
        guard path.hasPrefix("/"), path.count < 1_024 else { return nil }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// "copilot/gpt-4.1" → "gpt-4.1", "claude-opus-4-5-20251101" → "claude-opus-4-5"; nothing → "Unknown".
    static func modelName(_ raw: String?) -> String {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "Unknown" }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(range) }
        return name.isEmpty ? "Unknown" : String(name.prefix(64))
    }
}

/// Records without a usable timestamp are skipped rather than dated by file time, so an old session
/// touched today never inflates today's count.
enum AgentLocalTokens {
    private static let claudeUsageMarker = Data("\"usage\"".utf8)
    private static let codexUsageMarker = Data("\"token_count\"".utf8)
    private static let codexModelMarker = Data("\"turn_context\"".utf8)

    /// Today's local token usage for the given agents. Agents not asked for are not touched.
    static func today(
        for tools: Set<AgentTool>, now: Date = Date(), paths: AgentPaths = .init()
    ) -> [AgentTool: AgentTokenUsage] {
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
        let day = DateInterval(start: start, end: end)
        var result: [AgentTool: AgentTokenUsage] = [:]
        for tool in tools {
            if let usage = tokens(tool, day: day, paths: paths), usage.total > 0 {
                result[tool] = usage
            }
        }
        return result
    }

    private static func tokens(_ tool: AgentTool, day: DateInterval, paths: AgentPaths) -> AgentTokenUsage? {
        switch tool {
        case .claude:
            return claudeFormat(
                roots: [paths.claude.appendingPathComponent("projects"), paths.claude.appendingPathComponent("transcripts")],
                day: day)
        case .codex:
            let roots = [paths.codex.appendingPathComponent("sessions"), paths.codex.appendingPathComponent("archived_sessions")]
            return sum(recentFiles(in: roots, since: day.start)) { codexTokens($0, day: day) }
        case .openCode:
            return openCodeTokens(database: paths.data.appendingPathComponent("opencode/opencode.db"), day: day)
        case .copilot:
            guard let files = copilotSessionFiles(paths, since: day.start) else { return nil }
            var usage = AgentTokenUsage()
            var folders: [URL: String?] = [:]
            for file in files {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
                // workspaceStorage/<hash>/chatSessions/<file>: the workspace's folder is in <hash>/workspace.json.
                let workspace = file.deletingLastPathComponent().deletingLastPathComponent()
                if folders[workspace] == nil { folders[workspace] = copilotWorkspaceFolder(workspace) }
                usage = usage + copilotTokens(data, day: day, project: folders[workspace] ?? nil)
            }
            return usage
        case .gemini:
            let files = recentFiles(
                in: [paths.dot(".gemini").appendingPathComponent("tmp")], since: day.start, extensions: ["json", "jsonl"]
            ) {
                $0.pathExtension == "jsonl" || $0.lastPathComponent.hasPrefix("session-")
                    || $0.deletingLastPathComponent().lastPathComponent == "chats"
            }
            return sum(files) { geminiTokens($0, day: day) }
        case .qwen:
            return sum(recentFiles(in: [paths.dot(".qwen").appendingPathComponent("projects")], since: day.start)) {
                qwenTokens($0, day: day)
            }
        case .cline:
            let cli = recentFiles(in: [paths.clineSessions], since: day.start, extensions: ["json"]) {
                $0.lastPathComponent.hasSuffix(".messages.json")
            }
            return combine(
                extensionTasks(paths, id: "saoudrizwan.claude-dev", day: day, grossInput: { _, _ in false }),
                sum(cli) { clineCLITokens($0, day: day) })
        case .rooCode:
            return extensionTasks(paths, id: "rooveterinaryinc.roo-cline", day: day, grossInput: rooGrossInput)
        case .kiloCode:
            return combine(
                extensionTasks(paths, id: "kilocode.kilo-code", day: day, grossInput: rooGrossInput),
                openCodeTokens(database: paths.data.appendingPathComponent("kilo/kilo.db"), day: day))
        case .kimi:
            let wire: (URL) -> Bool = { $0.lastPathComponent == "wire.jsonl" }
            let roots = [
                paths.dot(".kimi").appendingPathComponent("sessions"), paths.kimiCode.appendingPathComponent("sessions"),
            ]
            return sum(recentFiles(in: roots, since: day.start, where: wire)) { kimiTokens($0, day: day) }
        case .pi:
            return piFormat(root: paths.dot(".pi").appendingPathComponent("agent/sessions"), day: day)
        case .ohMyPi:
            return piFormat(root: paths.dot(".omp").appendingPathComponent("agent/sessions"), day: day)
        case .cherryStudio:
            let base = paths.applicationSupport.appendingPathComponent("CherryStudio", isDirectory: true)
            return claudeFormat(
                roots: [
                    base.appendingPathComponent("Data/Agents/.claude/projects"), base.appendingPathComponent(".claude/projects"),
                ], day: day)
        case .zcode:
            // ZCode reports one computed total per call, so its tokens stay unclassified by type.
            var usage = AgentTokenUsage()
            let ok = sqliteRows(
                database: paths.dot(".zcode").appendingPathComponent("cli/db/db.sqlite"), day: day,
                sql: """
                    SELECT model_id, COALESCE(SUM(MAX(0, COALESCE(NULLIF(computed_total_tokens, 0), provider_total_tokens, 0))), 0)
                    FROM model_usage WHERE started_at >= ?1 AND started_at < ?2 GROUP BY model_id
                    """
            ) { row in usage.add(TokenTally(unclassified: row.int(1)), model: row.text(0)) }
            return ok ? usage : nil
        case .perch:
            // Perch reports context fill, not a token ledger; its card reads thread snapshots instead.
            return nil
        }
    }

    // MARK: - Shared helpers

    /// Adds per-file usage; returns nil (unknown) rather than a partial count if any file can't be read.
    private static func sum(_ files: [URL]?, _ count: (Data) -> AgentTokenUsage) -> AgentTokenUsage? {
        guard let files else { return nil }
        var usage = AgentTokenUsage()
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            usage = usage + count(data)
        }
        return usage
    }

    /// Two data sources for one agent: unknown only when both are.
    private static func combine(_ values: AgentTokenUsage?...) -> AgentTokenUsage? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(AgentTokenUsage(), +)
    }

    /// Scan budget: past this many recent files or bytes, report nothing rather than a partial count.
    private struct Budget {
        var files: [URL] = []
        private var bytes: Int64 = 0

        /// Adds `file` if it is a regular file modified since `start`. Returns false once over budget.
        mutating func add(_ file: URL, since start: Date) -> Bool {
            guard
                let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                info.isRegularFile == true, let modified = info.contentModificationDate, modified >= start,
                let size = info.fileSize
            else { return true }
            bytes += Int64(size)
            files.append(file)
            return files.count <= 250 && bytes <= 256_000_000
        }
    }

    private static func recentFiles(
        in roots: [URL], since start: Date, extensions: Set<String> = ["jsonl"], where include: (URL) -> Bool = { _ in true }
    ) -> [URL]? {
        var budget = Budget()
        for root in roots {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in enumerator where extensions.contains(file.pathExtension) && include(file) {
                guard budget.add(file, since: start) else { return nil }
            }
        }
        return budget.files
    }

    /// One result row of a read-only SQLite query.
    struct Row {
        fileprivate let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { max(0, sqlite3_column_int64(statement, column)) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    }

    /// Runs `sql` read-only with today's start and end (ms) bound to ?1 and ?2. False if the database or
    /// table is missing, so callers can report "unknown" rather than zero.
    private static func sqliteRows(database: URL, day: DateInterval, sql: String, row: (Row) -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: database.path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
            let db
        else { if db != nil { sqlite3_close(db) }; return false }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { if statement != nil { sqlite3_finalize(statement) }; return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(day.start.timeIntervalSince1970 * 1_000))
        sqlite3_bind_int64(statement, 2, Int64(day.end.timeIntervalSince1970 * 1_000))
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row(Row(statement: statement)); continue }
            return step == SQLITE_DONE
        }
    }

    private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    /// An ISO-8601 string, or a number of seconds or milliseconds since 1970.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let date = try? isoFractional.parse(text) { return date }
            if let date = try? isoPlain.parse(text) { return date }
            return Double(text).flatMap { date($0 as NSNumber) }
        }
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number >= 1e12 ? number / 1_000 : number)
    }

    static func count(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
            number.doubleValue >= 0, number.doubleValue <= 1_000_000_000,
            number.doubleValue.rounded(.down) == number.doubleValue
        else { return nil }
        return number.int64Value
    }

    private static func field(_ values: [String: Any]?, _ key: String) -> Int64 { count(values?[key]) ?? 0 }

    // MARK: - Claude Code format (also Cherry Studio)

    /// The largest snapshot of one API call, and its model.
    typealias Snapshot = (model: String?, project: String?, tally: TokenTally)

    private static func usage(_ snapshots: [String: Snapshot]) -> AgentTokenUsage {
        var usage = AgentTokenUsage()
        for snapshot in snapshots.values { usage.add(snapshot.tally, model: snapshot.model, project: snapshot.project) }
        return usage
    }

    private static func claudeFormat(roots: [URL], day: DateInterval) -> AgentTokenUsage? {
        guard let files = recentFiles(in: roots, since: day.start) else { return nil }
        var largest: [String: Snapshot] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            claudeTokens(data, day: day, into: &largest)
        }
        return usage(largest)
    }

    /// One API call can appear on several lines (one per content block, or as stream snapshots), so each
    /// request keeps its largest snapshot instead of being summed.
    static func claudeTokens(_ data: Data, day: DateInterval, into largest: inout [String: Snapshot]) {
        for line in data.split(separator: 10) {
            guard line.range(of: claudeUsageMarker) != nil else { continue }
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                root["type"] as? String == "assistant",
                let date = date(root["timestamp"] as? String), day.contains(date),
                let message = root["message"] as? [String: Any],
                message["model"] as? String != "<synthetic>",
                let key = (root["requestId"] as? String) ?? (message["requestId"] as? String) ?? (message["id"] as? String),
                !key.isEmpty, key.count < 256,
                let usage = message["usage"] as? [String: Any],
                count(usage["input_tokens"]) != nil, count(usage["output_tokens"]) != nil
            else { continue }
            let tally = TokenTally(
                input: field(usage, "input_tokens"), output: field(usage, "output_tokens"),
                cacheRead: field(usage, "cache_read_input_tokens"), cacheWrite: field(usage, "cache_creation_input_tokens"))
            if tally.total > (largest[key]?.tally.total ?? -1) {
                largest[key] = (message["model"] as? String, root["cwd"] as? String, tally)
            }
        }
    }

    // MARK: - Codex

    /// Codex logs running totals per session (`total_token_usage`), so today's share is the growth of each
    /// field. Cached input is part of `input_tokens` and reasoning part of `output_tokens`; both are split out.
    /// The model comes from the latest `turn_context` line.
    static func codexTokens(_ data: Data, day: DateInterval) -> AgentTokenUsage {
        struct Totals {
            var input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0
            var total: Int64 = 0
            init() {}
            init?(_ values: [String: Any]?) {
                guard let values, let total = AgentLocalTokens.count(values["total_tokens"]) else { return nil }
                input = AgentLocalTokens.field(values, "input_tokens")
                cached = AgentLocalTokens.field(values, "cached_input_tokens")
                cacheWrite = AgentLocalTokens.field(values, "cache_write_input_tokens")
                output = AgentLocalTokens.field(values, "output_tokens")
                reasoning = AgentLocalTokens.field(values, "reasoning_output_tokens")
                self.total = total
            }
            /// Growth since `earlier`; a smaller running total means a new session, so all of it counts.
            func since(_ earlier: Totals) -> Totals {
                guard total >= earlier.total else { return self }
                var result = Totals()
                result.input = max(0, input - earlier.input)
                result.cached = max(0, cached - earlier.cached)
                result.cacheWrite = max(0, cacheWrite - earlier.cacheWrite)
                result.output = max(0, output - earlier.output)
                result.reasoning = max(0, reasoning - earlier.reasoning)
                result.total = total - earlier.total
                return result
            }
            var tally: TokenTally {
                let split = TokenTally(
                    input: max(0, input - cached - cacheWrite), output: max(0, output - reasoning),
                    reasoning: min(reasoning, output),
                    cacheRead: min(cached, input), cacheWrite: min(cacheWrite, max(0, input - cached)))
                // Only the total is trusted when the parts don't add up to it.
                return split.total == total ? split : TokenTally(unclassified: total)
            }
        }
        var usage = AgentTokenUsage()
        var previous = Totals()
        var model: String?
        var folder: String?
        for line in data.split(separator: 10) {
            if line.range(of: codexModelMarker) != nil,
                let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                root["type"] as? String == "turn_context",
                let payload = root["payload"] as? [String: Any]
            {
                model = payload["model"] as? String ?? model
                folder = payload["cwd"] as? String ?? folder
                continue
            }
            guard line.range(of: codexUsageMarker) != nil else { continue }
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                root["type"] as? String == "event_msg",
                let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                let date = date(root["timestamp"] as? String),
                let info = payload["info"] as? [String: Any]
            else { continue }
            if let current = Totals(info["total_token_usage"] as? [String: Any]) {
                if day.contains(date) { usage.add(current.since(previous).tally, model: model, project: folder) }
                previous = current
            } else if day.contains(date), let last = Totals(info["last_token_usage"] as? [String: Any]) {
                usage.add(last.tally, model: model, project: folder)
            }
        }
        return usage
    }

    // MARK: - OpenCode schema (OpenCode, Kilo CLI)

    /// Current OpenCode keeps `session_message`; older OpenCode and Kilo keep `message` with times inside the JSON.
    /// Only assistant usage fields and model names are extracted; message text is never returned to Swift.
    static func openCodeTokens(database: URL, day: DateInterval) -> AgentTokenUsage? {
        func column(_ path: String) -> String {
            "COALESCE(SUM(MAX(0, COALESCE(CAST(json_extract(m.data,'$.tokens.\(path)') AS INTEGER), 0))), 0)"
        }
        func select(folder: String) -> String {
            """
            SELECT COALESCE(json_extract(m.data,'$.model.id'), json_extract(m.data,'$.modelID')), \(folder),
            \(column("input")), \(column("output")), \(column("reasoning")), \(column("cache.read")), \(column("cache.write"))
            """
        }
        func run(_ sql: String) -> AgentTokenUsage? {
            var usage = AgentTokenUsage()
            let ok = sqliteRows(database: database, day: day, sql: sql) { row in
                usage.add(
                    TokenTally(
                        input: row.int(2), output: row.int(3), reasoning: row.int(4), cacheRead: row.int(5),
                        cacheWrite: row.int(6)),
                    model: row.text(0), project: row.text(1))
            }
            return ok ? usage : nil
        }
        let current = """
            WHERE m.type = 'assistant' AND m.time_created >= ?1 AND m.time_created < ?2 AND json_valid(m.data) GROUP BY 1, 2
            """
        return run(
            "\(select(folder: "s.directory")) FROM session_message m LEFT JOIN session_v2 s ON s.id = m.session_id \(current)")
            ?? run("\(select(folder: "NULL")) FROM session_message m \(current)")
            ?? run(
                """
                \(select(folder: "NULL")) FROM message m
                WHERE json_valid(m.data) AND json_extract(m.data,'$.role') = 'assistant'
                AND CAST(json_extract(m.data,'$.time.created') AS INTEGER) >= ?1
                AND CAST(json_extract(m.data,'$.time.created') AS INTEGER) < ?2 GROUP BY 1, 2
                """)
    }

    // MARK: - GitHub Copilot Chat (VS Code)

    /// `workspaceStorage/<hash>/chatSessions/*.jsonl` plus empty-window sessions, without walking the
    /// (often multi-GB) workspace folders themselves. VS Code can keep the same session in both places,
    /// so each file name is read once, preferring the workspace copy.
    private static func copilotSessionFiles(_ paths: AgentPaths, since start: Date) -> [URL]? {
        let manager = FileManager.default
        var folders: [URL] = []
        for user in paths.vscodeUsers {
            let storage = user.appendingPathComponent("workspaceStorage", isDirectory: true)
            for workspace in (try? manager.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [] {
                folders.append(workspace.appendingPathComponent("chatSessions", isDirectory: true))
            }
            folders.append(user.appendingPathComponent("globalStorage/emptyWindowChatSessions", isDirectory: true))
        }
        var budget = Budget()
        var names = Set<String>()
        for folder in folders {
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "jsonl" && !names.contains(file.lastPathComponent) {
                let before = budget.files.count
                guard budget.add(file, since: start) else { return nil }
                if budget.files.count > before { names.insert(file.lastPathComponent) }
            }
        }
        return budget.files
    }

    /// Copilot Chat stores each session as a change log: `kind 0` is a snapshot, `kind 1` sets the value at
    /// path `k`, `kind 2` appends to the array at `k` (truncating to index `i` first when given). Only
    /// request times, models and `promptTokens`/`completionTokens` are kept; message text is never retained.
    /// The folder a VS Code workspace has open (`workspace.json` → `folder`), if it is one folder.
    private static func copilotWorkspaceFolder(_ workspace: URL) -> String? {
        guard let data = try? Data(contentsOf: workspace.appendingPathComponent("workspace.json")), data.count < 64_000,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["folder"] as? String
    }

    static func copilotTokens(_ data: Data, day: DateInterval, project: String? = nil) -> AgentTokenUsage {
        struct Request {
            var time: Date?
            var model: String?
            var prompt: Int64
            var completion: Int64
            init(_ object: Any) {
                let values = object as? [String: Any]
                let metadata = (values?["result"] as? [String: Any])?["metadata"] as? [String: Any]
                time = AgentLocalTokens.date(values?["timestamp"] as? NSNumber)
                model = (metadata?["resolvedModel"] as? String) ?? (values?["modelId"] as? String)
                prompt = AgentLocalTokens.count(values?["promptTokens"] ?? metadata?["promptTokens"]) ?? 0
                completion = AgentLocalTokens.count(values?["completionTokens"] ?? metadata?["outputTokens"]) ?? 0
            }
        }
        var requests: [Request] = []
        for root in lines(data) {
            guard let kind = (root["kind"] as? NSNumber)?.intValue else { continue }
            let path = root["k"] as? [Any] ?? []
            let underRequests = path.first as? String == "requests"
            switch kind {
            case 0:
                requests = ((root["v"] as? [String: Any])?["requests"] as? [Any] ?? []).map(Request.init)
            case 1 where underRequests && path.count == 1:
                requests = (root["v"] as? [Any] ?? []).map(Request.init)
            case 1 where underRequests && path.count == 3:
                guard let index = (path[1] as? NSNumber)?.intValue, requests.indices.contains(index) else { continue }
                switch path[2] as? String {
                case "promptTokens": if let value = count(root["v"]) { requests[index].prompt = value }
                case "completionTokens": if let value = count(root["v"]) { requests[index].completion = value }
                case "modelId": if let value = root["v"] as? String { requests[index].model = value }
                default: break
                }
            case 2 where underRequests && path.count == 1:
                if let cut = (root["i"] as? NSNumber)?.intValue, cut >= 0, cut < requests.count {
                    requests.removeSubrange(cut...)
                }
                requests += (root["v"] as? [Any] ?? []).map(Request.init)
            default: continue
            }
        }
        var usage = AgentTokenUsage()
        for request in requests {
            guard let time = request.time, day.contains(time) else { continue }
            usage.add(TokenTally(input: request.prompt, output: request.completion), model: request.model, project: project)
        }
        return usage
    }

    // MARK: - Gemini CLI

    /// `.json` recordings hold `messages`; `.jsonl` recordings hold one message per line. A streamed
    /// message is rewritten under the same `id`, so the last copy wins.
    static func geminiTokens(_ data: Data, day: DateInterval) -> AgentTokenUsage {
        let messages: [[String: Any]]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            messages = object["messages"] as? [[String: Any]] ?? []
        } else {
            messages = lines(data)
        }
        var byID: [String: Snapshot] = [:]
        var usage = AgentTokenUsage()
        for message in messages {
            guard let tokens = message["tokens"] as? [String: Any],
                let date = date(message["timestamp"] ?? message["created_at"]), day.contains(date)
            else { continue }
            // The prompt includes cached tokens; thoughts are reported apart from the answer.
            let prompt = field(tokens, "input") + field(tokens, "tool")
            let cached = min(field(tokens, "cached"), prompt)
            var tally = TokenTally(
                input: prompt - cached, output: field(tokens, "output"), reasoning: field(tokens, "thoughts"), cacheRead: cached)
            let reported = field(tokens, "total")
            if reported > 0, reported != tally.total { tally = TokenTally(unclassified: reported) }
            let model = message["model"] as? String
            if let id = message["id"] as? String { byID[id] = (model, nil, tally) } else { usage.add(tally, model: model) }
        }
        return usage + self.usage(byID)
    }

    // MARK: - Qwen Code

    static func qwenTokens(_ data: Data, day: DateInterval) -> AgentTokenUsage {
        var usage = AgentTokenUsage()
        for line in lines(data) {
            guard line["type"] as? String == "assistant", let meta = line["usageMetadata"] as? [String: Any],
                let date = date(line["timestamp"]), day.contains(date)
            else { continue }
            let prompt = field(meta, "promptTokenCount"), candidates = field(meta, "candidatesTokenCount")
            let thoughts = field(meta, "thoughtsTokenCount"), reported = field(meta, "totalTokenCount")
            let cached = min(field(meta, "cachedContentTokenCount"), prompt)
            // Thoughts are inside the candidates when the reported total is just prompt + candidates.
            let thoughtsInside = thoughts > 0 && reported > 0 && reported == prompt + candidates
            let reasoning = thoughtsInside ? min(thoughts, candidates) : thoughts
            var tally = TokenTally(
                input: prompt - cached, output: candidates - (thoughtsInside ? reasoning : 0), reasoning: reasoning,
                cacheRead: cached)
            if reported > 0, reported != tally.total { tally = TokenTally(unclassified: reported) }
            usage.add(tally, model: line["model"] as? String)
        }
        return usage
    }

    // MARK: - Cline, Roo Code, Kilo Code (VS Code extensions)

    /// Roo and Kilo Code switched `tokensIn` to include cache on 2 Nov 2025, and always do so for OpenAI-style APIs.
    private static func rooGrossInput(_ time: Date, _ request: [String: Any]) -> Bool {
        time.timeIntervalSince1970 >= 1_762_041_600
            || (request["apiProtocol"] as? String)?.split(separator: "/").last == "openai"
    }

    private static func extensionTasks(
        _ paths: AgentPaths, id: String, day: DateInterval, grossInput: (Date, [String: Any]) -> Bool
    ) -> AgentTokenUsage? {
        let manager = FileManager.default
        var budget = Budget()
        for user in paths.editorUsers {
            let tasks = user.appendingPathComponent("globalStorage/\(id)/tasks", isDirectory: true)
            for task in (try? manager.contentsOfDirectory(at: tasks, includingPropertiesForKeys: nil)) ?? [] {
                guard budget.add(task.appendingPathComponent("ui_messages.json"), since: day.start) else { return nil }
            }
        }
        return sum(budget.files) { extensionTaskTokens($0, day: day, grossInput: grossInput) }
    }

    /// `ui_messages.json` is an array of UI events; each `api_req_started` event's `text` is a JSON string
    /// holding that request's token counts.
    static func extensionTaskTokens(
        _ data: Data, day: DateInterval, grossInput: (Date, [String: Any]) -> Bool
    ) -> AgentTokenUsage {
        var usage = AgentTokenUsage()
        guard let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return usage }
        for event in events {
            guard event["type"] as? String == "say", event["say"] as? String == "api_req_started",
                let date = date(event["ts"]), day.contains(date),
                let text = event["text"] as? String,
                let request = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { continue }
            let reads = field(request, "cacheReads"), writes = field(request, "cacheWrites")
            let input = field(request, "tokensIn")
            let tally = TokenTally(
                input: grossInput(date, request) ? max(0, input - reads - writes) : input,
                output: field(request, "tokensOut"), cacheRead: reads, cacheWrite: writes)
            usage.add(tally, model: (event["modelInfo"] as? [String: Any])?["modelId"] as? String)
        }
        return usage
    }

    /// Cline CLI sessions: `messages[]` with per-reply `metrics`; `inputTokens` already includes cache.
    static func clineCLITokens(_ data: Data, day: DateInterval) -> AgentTokenUsage {
        var usage = AgentTokenUsage()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let messages = object["messages"] as? [[String: Any]]
        else { return usage }
        for message in messages {
            guard message["role"] as? String == "assistant", let metrics = message["metrics"] as? [String: Any],
                let date = date(message["ts"]), day.contains(date)
            else { continue }
            let reads = field(metrics, "cacheReadTokens"), writes = field(metrics, "cacheWriteTokens")
            let tally = TokenTally(
                input: max(0, field(metrics, "inputTokens") - reads - writes), output: field(metrics, "outputTokens"),
                cacheRead: reads, cacheWrite: writes)
            usage.add(tally, model: (message["modelInfo"] as? [String: Any])?["id"] as? String)
        }
        return usage
    }

    // MARK: - Kimi

    /// Kimi Code logs `usage.record` lines (count only `usageScope == "turn"`; `step.end` repeats them).
    /// Legacy Kimi CLI logs `StatusUpdate` snapshots per `message_id`; the largest one wins.
    static func kimiTokens(_ data: Data, day: DateInterval) -> AgentTokenUsage {
        var usage = AgentTokenUsage()
        var snapshots: [String: Snapshot] = [:]
        for line in lines(data) {
            if line["type"] as? String == "usage.record" {
                guard line["usageScope"] as? String == "turn", let date = date(line["time"]), day.contains(date) else { continue }
                let values = line["usage"] as? [String: Any]
                let tally = TokenTally(
                    input: field(values, "inputOther"), output: field(values, "output"),
                    cacheRead: field(values, "inputCacheRead"), cacheWrite: field(values, "inputCacheCreation"))
                usage.add(tally, model: line["model"] as? String)
            } else if let message = line["message"] as? [String: Any], message["type"] as? String == "StatusUpdate",
                let payload = message["payload"] as? [String: Any],
                let date = date(line["timestamp"]), day.contains(date)
            {
                let values = payload["token_usage"] as? [String: Any]
                let tally = TokenTally(
                    input: field(values, "input_other"), output: field(values, "output"),
                    cacheRead: field(values, "input_cache_read"), cacheWrite: field(values, "input_cache_creation"))
                if let id = payload["message_id"] as? String {
                    if tally.total > (snapshots[id]?.tally.total ?? -1) { snapshots[id] = (nil, nil, tally) }
                } else {
                    usage.add(tally, model: nil)
                }
            }
        }
        return usage + self.usage(snapshots)
    }

    // MARK: - Pi, Oh My Pi

    /// Forked sessions copy earlier replies into new files, so replies are keyed by `responseId` across all files.
    private static func piFormat(root: URL, day: DateInterval) -> AgentTokenUsage? {
        guard let files = recentFiles(in: [root], since: day.start) else { return nil }
        var largest: [String: Snapshot] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            piTokens(data, day: day, into: &largest)
        }
        return usage(largest)
    }

    static func piTokens(_ data: Data, day: DateInterval, into largest: inout [String: Snapshot]) {
        let entries = lines(data)
        // A session file starts with its `session` record (optionally after `title` lines).
        guard entries.first(where: { $0["type"] as? String != "title" })?["type"] as? String == "session" else { return }
        for entry in entries {
            let message = entry["message"] as? [String: Any]
            guard let values = (message?["usage"] ?? entry["usage"]) as? [String: Any] else { continue }
            let role = message?["role"] as? String
            let type = entry["type"] as? String ?? ""
            guard role == "assistant" || role == "toolResult" || ["compaction", "branch_summary", "usage"].contains(type)
            else { continue }
            let started = (count(message?["durationMs"]) ?? 0) > 0 ? date(message?["timestamp"]) : nil
            guard let date = started ?? date(entry["timestamp"]), day.contains(date) else { continue }
            // `reasoning` is part of `output` here, so it isn't added again.
            let tally = TokenTally(
                input: field(values, "input"), output: field(values, "output"), cacheRead: field(values, "cacheRead"),
                cacheWrite: field(values, "cacheWrite"))
            let key =
                (message?["responseId"] as? String).map { "response:\($0)" }
                ?? "\(type):\(entry["id"] as? String ?? ""):\(date.timeIntervalSince1970):\(tally.total)"
            if tally.total > (largest[key]?.tally.total ?? -1) { largest[key] = (message?["model"] as? String, nil, tally) }
        }
    }
}
