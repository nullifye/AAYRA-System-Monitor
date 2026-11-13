import Compression
import Foundation
import SQLite3

/// Current-window usage is separate from today's cumulative token spend.
struct AgentContextReading: Equatable, Sendable {
    let percent: Double?
    let used: Int64?
    let capacity: Int64?
    let model: String?
    let observedAt: Date?
    let detail: String

    static let unavailable = Self(
        percent: nil, used: nil, capacity: nil, model: nil, observedAt: nil,
        detail: "No recent context reading with a known model capacity")
}

/// Read-only adapters for the agents' native session files. No prompt is sent to obtain a reading.
enum AgentContextUsage {
    private static let maximumAge: TimeInterval = 86_400
    private static let maximumFileSize = 8_000_000

    static func read(for tools: Set<AgentTool>, paths: AgentPaths = .init(), now: Date = Date()) -> [AgentTool:
        AgentContextReading]
    {
        var result: [AgentTool: AgentContextReading] = [:]
        for tool in tools where tool.readsLocalContext {
            let configured = configuredLimits(tool, paths: paths)
            var reading: AgentContextReading?
            if tool == .kiloCode || tool == .zcode {
                let database =
                    tool == .kiloCode
                    ? paths.data.appendingPathComponent("kilo/kilo.db")
                    : paths.dot(".zcode").appendingPathComponent("cli/db/db.sqlite")
                reading = databaseReading(database, tool: tool, limits: configured, now: now)
            }
            if let file = newestFile(tool, paths: paths, now: now),
                let data = boundedData(file),
                let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            {
                let candidate = parse(data, tool: tool, limits: configured, observedAt: modified)
                if reading == nil || (candidate.observedAt ?? modified) > (reading?.observedAt ?? .distantPast) {
                    reading = candidate
                }
            }
            result[tool] = reading ?? .unavailable
        }
        return result
    }

    /// Explicit recorded/configured capacity wins. The catalog is only a labelled estimate for an exact model id.
    static func parse(
        _ data: Data, tool: AgentTool, limits: [String: Int64] = [:], observedAt: Date = Date()
    ) -> AgentContextReading {
        let records: [[String: Any]]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            records = array
        } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            records = (object["messages"] as? [[String: Any]]) ?? [object]
        } else {
            records = data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        var model: String?
        var provider: String?
        var reading: AgentContextReading?
        var kimiUsed: Int64?, kimiCapacity: Int64?
        // A Pi branch can rewind: only walk ancestors of the current leaf, never a discarded branch.
        let active = records.contains(where: { $0["type"] as? String == "session" }) ? activeBranch(records) : records
        for record in active {
            let type = record["type"] as? String ?? ""
            let message = record["message"] as? [String: Any] ?? record
            let eventType = message["type"] as? String ?? type
            if type == "model_change" {
                model = (record["modelId"] ?? record["model"]) as? String
                provider = record["provider"] as? String
                reading = nil
            }
            let subtype = record["subtype"] as? String ?? ""
            if ["compaction", "branch_summary", "CompactionBegin", "CompactionEnd"].contains(eventType)
                || subtype == "chat_compression" || record["say"] as? String == "context_condensed"
            {
                reading = nil
                kimiUsed = nil
                kimiCapacity = nil
                continue
            }
            let payload =
                message["payload"] as? [String: Any] ?? record["payload"] as? [String: Any]
                ?? (record["success"] as? Bool == true ? record["data"] as? [String: Any] : nil) ?? message
            let time = AgentLocalTokens.date(record["timestamp"] ?? record["ts"] ?? record["time"]) ?? observedAt
            if tool == .kimi, message["type"] as? String == "StatusUpdate" {
                if let value = count(payload["context_tokens"]) { kimiUsed = value }
                if let value = count(payload["max_context_tokens"]), value > 0 { kimiCapacity = value }
                if let fraction = number(payload["context_usage"]), (0...1).contains(fraction) {
                    reading = .init(
                        percent: fraction * 100, used: kimiUsed, capacity: kimiCapacity, model: model,
                        observedAt: time, detail: "Agent-reported context used")
                } else if let used = kimiUsed, let capacity = kimiCapacity {
                    reading = make(used: used, capacity: capacity, model: model, time: time, estimated: false)
                }
                continue
            }
            // Native RPC/context snapshots, including Cherry's ThreadContextUsage and ZCode's projection.
            if let snapshot = (payload["contextUsage"] ?? payload["context_usage"]) as? [String: Any]
                ?? (payload["contextWindow"] as? [String: Any])
            {
                let usedObject = snapshot["used"] as? [String: Any]
                let used = count(snapshot["tokens"] ?? snapshot["usedTokens"] ?? usedObject?["tokens"])
                let capacity = count(snapshot["contextWindow"] ?? snapshot["maxTokens"] ?? snapshot["window_size_tokens"])
                if let used, let capacity {
                    reading = make(used: used, capacity: capacity, model: model, time: time, estimated: false)
                } else if let percent = number(snapshot["percent"]), (0...100).contains(percent) {
                    reading = .init(
                        percent: percent, used: used, capacity: capacity, model: model, observedAt: time,
                        detail: "Agent-reported context used")
                } else {
                    reading = nil
                }
                continue
            }
            if ["aborted", "error"].contains(message["stopReason"] as? String ?? "") { continue }
            if let value = message["model"] as? String, !value.isEmpty { model = value }
            if let value = message["modelID"] as? String { model = value }
            if let value = message["provider"] as? String ?? message["providerID"] as? String { provider = value }
            let info = record["modelInfo"] as? [String: Any] ?? message["modelInfo"] as? [String: Any] ?? [:]
            model = (info["modelId"] ?? info["id"]) as? String ?? model
            provider = info["providerId"] as? String ?? provider
            var explicitCapacity = count(record["contextWindowSize"] ?? info["contextWindow"] ?? message["contextWindow"])
            var used: Int64?
            if tool == .qwen, type == "assistant", let usage = record["usageMetadata"] as? [String: Any] {
                used = count(usage["promptTokenCount"])
            } else if [AgentTool.cline, .rooCode, .kiloCode].contains(tool),
                record["say"] as? String == "api_req_started", let text = record["text"] as? String,
                let request = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                let input = count(request["tokensIn"])
            {
                let cache = tool == .cline ? (count(request["cacheReads"]) ?? 0) + (count(request["cacheWrites"]) ?? 0) : 0
                used = input + cache + (count(request["tokensOut"]) ?? 0)
                explicitCapacity = count(request["contextWindow"]) ?? explicitCapacity
            } else if message["role"] as? String == "assistant" || type == "assistant" {
                if let metrics = message["metrics"] as? [String: Any], let input = count(metrics["inputTokens"]) {
                    used = input + (count(metrics["outputTokens"]) ?? 0)
                } else if let usage = message["usage"] as? [String: Any] {
                    if let input = count(usage["input_tokens"]) {
                        used =
                            input + (count(usage["cache_read_input_tokens"]) ?? 0)
                            + (count(usage["cache_creation_input_tokens"]) ?? 0) + (count(usage["output_tokens"]) ?? 0)
                    } else if let input = count(usage["input"]) {
                        used =
                            count(usage["contextTokens"])
                            ?? (input + (count(usage["output"]) ?? 0)
                                + (count(usage["cacheRead"]) ?? 0) + (count(usage["cacheWrite"]) ?? 0))
                    }
                } else if let tokens = message["tokens"] as? [String: Any], let input = count(tokens["input"]) {
                    let cache = tokens["cache"] as? [String: Any] ?? [:]
                    used =
                        input + (count(tokens["output"]) ?? 0) + (count(tokens["reasoning"]) ?? 0)
                        + (count(cache["read"]) ?? 0) + (count(cache["write"]) ?? 0)
                }
            }
            guard let used else { continue }
            let configured = model.flatMap { model in
                provider.flatMap { limits[$0 + "/" + model] } ?? limits[model]
            }
            let capacity = explicitCapacity ?? configured ?? AgentContextModels.capacity(model: model, provider: provider)
            if let capacity {
                reading = make(used: used, capacity: capacity, model: model, time: time, estimated: true)
            } else {
                reading = .init(
                    percent: nil, used: used, capacity: nil, model: model, observedAt: time,
                    detail: "Context capacity unavailable for this model")
            }
        }
        return reading
            ?? .init(
                percent: nil, used: nil, capacity: nil, model: model, observedAt: observedAt,
                detail: "No valid current context reading; a response may be needed after compaction")
    }

    private static func make(used: Int64, capacity: Int64, model: String?, time: Date, estimated: Bool) -> AgentContextReading? {
        guard capacity > 0 else { return nil }
        return .init(
            percent: min(100, Double(used) / Double(capacity) * 100), used: used, capacity: capacity, model: model,
            observedAt: time, detail: estimated ? "Estimated context used from the last response" : "Agent-reported context used")
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
            value.doubleValue >= 0
        else { return nil }
        return value.doubleValue
    }

    private static func count(_ value: Any?) -> Int64? {
        guard let value = number(value), value <= 1_000_000_000, value.rounded(.down) == value else { return nil }
        return Int64(value)
    }

    private static func activeBranch(_ records: [[String: Any]]) -> [[String: Any]] {
        guard let leaf = records.last(where: { $0["id"] is String && $0.keys.contains("parentId") }),
            var id = leaf["id"] as? String
        else { return records }
        var byID: [String: [String: Any]] = [:]
        for record in records { if let id = record["id"] as? String { byID[id] = record } }
        var branch: [[String: Any]] = [], seen = Set<String>()
        while seen.insert(id).inserted, let record = byID[id] {
            branch.append(record)
            guard let parent = record["parentId"] as? String else { break }
            id = parent
        }
        return branch.reversed()
    }

    private static func boundedData(_ file: URL) -> Data? {
        guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            info.isRegularFile == true, let size = info.fileSize, size <= maximumFileSize
        else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    private static func newestFile(_ tool: AgentTool, paths: AgentPaths, now: Date) -> URL? {
        var newest: (URL, Date)?, scanned = 0
        for root in tool.contextRoots(paths) {
            guard
                let files = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in files {
                scanned += 1
                guard scanned <= 4_000 else { return nil }
                guard ["jsonl", "json"].contains(file.pathExtension), tool.acceptsContextFile(file),
                    let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                    info.isRegularFile == true, let time = info.contentModificationDate,
                    time <= now.addingTimeInterval(60), now.timeIntervalSince(time) <= maximumAge
                else { continue }
                if time > (newest?.1 ?? .distantPast) { newest = (file, time) }
            }
        }
        return newest?.0
    }

    private static func configuredLimits(_ tool: AgentTool, paths: AgentPaths) -> [String: Int64] {
        let files: [URL]
        switch tool {
        case .pi: files = [paths.dot(".pi").appendingPathComponent("agent/models.json")]
        case .ohMyPi: files = [paths.dot(".omp").appendingPathComponent("agent/models.json")]
        case .qwen: files = [paths.dot(".qwen").appendingPathComponent("settings.json")]
        case .zcode: files = [paths.dot(".zcode").appendingPathComponent("cli/config.json")]
        default: files = []
        }
        var candidates: [String: Set<Int64>] = [:]
        func visit(_ object: Any, provider: String? = nil) {
            if let list = object as? [Any] {
                for value in list { visit(value, provider: provider) }
                return
            }
            guard let object = object as? [String: Any] else { return }
            let config = object["generationConfig"] as? [String: Any] ?? object
            if let model = (object["id"] ?? object["modelId"]) as? String,
                let size = count(config["contextWindow"] ?? config["contextWindowSize"]), size > 0
            {
                candidates[provider.map { $0 + "/" + model } ?? model, default: []].insert(size)
                candidates[model, default: []].insert(size)
            }
            for (key, value) in object where key != "apiKey" && key != "headers" && key != "env" {
                if key == "providers" || key == "modelProviders", let providers = value as? [String: Any] {
                    for (id, config) in providers { visit(config, provider: id) }
                } else {
                    visit(value, provider: provider)
                }
            }
        }
        for file in files {
            if let data = boundedData(file), let object = try? JSONSerialization.jsonObject(with: data) { visit(object) }
        }
        return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private static func databaseReading(
        _ file: URL, tool: AgentTool, limits: [String: Int64], now: Date
    ) -> AgentContextReading? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
            let database
        else { if let database { sqlite3_close(database) }; return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        // Return only usage/model metadata to Swift; never read conversation content from SQLite.
        let projection = """
            json_object('role','assistant','modelID',json_extract(data,'$.modelID'),
            'model',COALESCE(json_extract(data,'$.modelSelection.modelId'),json_extract(data,'$.model.id'),json_extract(data,'$.model')),
            'providerID',COALESCE(json_extract(data,'$.modelSelection.providerId'),json_extract(data,'$.providerID')),
            'tokens',json_extract(data,'$.tokens'),'usage',json_extract(data,'$.usage'),
            'contextWindow',json_extract(data,'$.contextWindow'))
            """
        var queries: [String] = []
        for table in ["session_message", "message"] {
            let isAssistant = table == "session_message" ? "type = 'assistant'" : "json_extract(data,'$.role') = 'assistant'"
            queries.append(
                """
                SELECT \(projection), time_created FROM \(table)
                WHERE json_valid(data) AND \(isAssistant)
                ORDER BY time_created DESC LIMIT 1
                """)
        }
        if tool == .zcode {
            queries.append(
                """
                SELECT json_object('role','assistant','model',model_id,'provider',provider_id,
                'usage',json_object('input',input_tokens,'output',output_tokens,
                'cacheRead',cache_read_input_tokens,'cacheWrite',cache_creation_input_tokens)), started_at
                FROM model_usage WHERE error_type IS NULL AND cancelled_by_user = 0
                AND computed_total_tokens > 0 AND LOWER(COALESCE(query_source,'')) NOT LIKE '%compact%'
                ORDER BY started_at DESC LIMIT 1
                """)
        }
        for sql in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { continue }
            let time = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1_000)
            guard now.timeIntervalSince(time) <= maximumAge else { return nil }
            let result = parse(Data(String(cString: raw).utf8), tool: tool, limits: limits, observedAt: time)
            if result.used != nil { return result }
        }
        return nil
    }
}

/// Model capacities for agents whose records say how many tokens are in the window but not how big
/// the window is. The bundled catalog is a capacity-only snapshot of the Oh My Pi model catalog,
/// folded (one bare key where every provider agrees) and shipped as a raw DEFLATE stream: 31 KB
/// instead of 227 KB of JSON. It is read once, lazily, and never fetched from the network.
enum AgentContextModels {
    private static let models: [String: Int64] = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentContextModels.deflate")
        let url = Bundle.main.url(forResource: "AgentContextModels", withExtension: "deflate") ?? source
        guard let stream = try? Data(contentsOf: url), let data = inflate(stream),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [String: Int64]
        else { return [:] }
        return models
    }()

    /// Raw DEFLATE, which is what a gzip file holds without its container; Apple's decoder reads
    /// that directly and does not accept the wrapper. The buffer grows until the catalog fits.
    private static func inflate(_ stream: Data) -> Data? {
        var capacity = 1 << 18
        while capacity <= 8 << 20 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                stream.withUnsafeBytes { input in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        input.bindMemory(to: UInt8.self).baseAddress!, stream.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return output.prefix(written) }
            capacity <<= 2
        }
        return nil
    }

    static func capacity(model: String?, provider: String?) -> Int64? {
        guard let model, !model.isEmpty else { return nil }
        if let provider, let size = models[provider + "/" + model] { return size }
        if let size = models[model] { return size }
        // An unqualified id is safe only if every provider agrees on its capacity.
        let matches = Set(models.filter { $0.key.hasSuffix("/" + model) }.values)
        return matches.count == 1 ? matches.first : nil
    }
}

extension AgentTool {
    var readsLocalContext: Bool { menuBarPercentageMeaning == .used && self != .perch }

    fileprivate func contextRoots(_ paths: AgentPaths) -> [URL] {
        switch self {
        case .qwen: [paths.dot(".qwen").appendingPathComponent("projects")]
        case .cline, .rooCode, .kiloCode:
            paths.editorUsers.map {
                let id =
                    self == .cline
                    ? "saoudrizwan.claude-dev" : self == .rooCode ? "rooveterinaryinc.roo-cline" : "kilocode.kilo-code"
                return $0.appendingPathComponent("globalStorage/\(id)/tasks")
            } + (self == .cline ? [paths.clineSessions] : [])
        case .kimi:
            [paths.dot(".kimi").appendingPathComponent("sessions"), paths.kimiCode.appendingPathComponent("sessions")]
        case .pi: [paths.dot(".pi").appendingPathComponent("agent/sessions")]
        case .ohMyPi: [paths.dot(".omp").appendingPathComponent("agent/sessions")]
        case .cherryStudio:
            [
                paths.applicationSupport.appendingPathComponent("CherryStudio/Data/Agents/.claude/projects"),
                paths.applicationSupport.appendingPathComponent("CherryStudio/.claude/projects"),
                paths.applicationSupport.appendingPathComponent("CherryStudio/Data/Agents"),
            ]
        case .zcode: []  // The database is authoritative; log-file modification times are not context readings.
        default: []
        }
    }

    fileprivate func acceptsContextFile(_ file: URL) -> Bool {
        switch self {
        case .cline, .rooCode, .kiloCode:
            file.lastPathComponent == "ui_messages.json" || file.lastPathComponent.hasSuffix(".messages.json")
        case .kimi: file.lastPathComponent == "wire.jsonl"
        default: file.pathExtension == "jsonl"
        }
    }
}
