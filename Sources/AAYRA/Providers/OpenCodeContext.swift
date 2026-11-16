import Foundation

/// Bounded, metadata-only context estimate for the most recently used OpenCode conversation.
/// Daily totals and account quota are deliberately separate; no server, credentials or prompt are needed.
enum OpenCodeContext {
    static func read(database: URL, now: Date = Date()) -> AgentContextReading? {
        // Current OpenCode stores model objects in session_message. Older versions keep modelID/providerID
        // in message. Project only usage/model metadata; conversation content never crosses into Swift.
        let projection = """
            json_object('role','assistant',
            'modelID',COALESCE(json_extract(data,'$.model.id'),json_extract(data,'$.modelID')),
            'providerID',COALESCE(json_extract(data,'$.model.providerID'),json_extract(data,'$.providerID')),
            'tokens',json_extract(data,'$.tokens'),
            'error',CASE WHEN json_type(data,'$.error') = 'object' THEN json('{}') ELSE NULL END,
            'finish',json_extract(data,'$.finish'),
            'contextWindow',json_extract(data,'$.contextWindow'))
            """
        for (table, type, order) in [
            ("session_message", "type", "seq"),
            ("session_message", "type", "time_created"),
            (
                "message", "CASE WHEN json_extract(data,'$.summary') = 1 THEN 'compaction' ELSE json_extract(data,'$.role') END",
                "time_created"
            ),
        ] {
            let sql = """
                SELECT \(type), \(projection), time_created FROM \(table)
                WHERE session_id = (SELECT session_id FROM \(table) ORDER BY time_created DESC LIMIT 1)
                AND json_valid(data) ORDER BY \(order) DESC LIMIT 64
                """
            var records: [(type: String, data: Data, time: Date)] = []
            let ok = AgentLocalTokens.sqliteRows(database: database, sql: sql) { row in
                guard let type = row.text(0), let text = row.text(1) else { return }
                records.append((type, Data(text.utf8), Date(timeIntervalSince1970: Double(row.int(2)) / 1000)))
            }
            guard ok, !records.isEmpty else { continue }
            for record in records {
                guard record.time <= now.addingTimeInterval(60), now.timeIntervalSince(record.time) <= 86_400 else {
                    return nil
                }
                // Never resurrect pre-compaction or previous-model usage. A new response must establish
                // a fresh reading. The selected session also prevents inheriting another session's window.
                if ["compaction", "model-switched"].contains(record.type) {
                    return .init(
                        percent: nil, used: nil, capacity: nil, model: nil, observedAt: record.time,
                        detail: "Waiting for a response after compaction or a model change")
                }
                guard record.type == "assistant",
                    let metadata = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any],
                    metadata["finish"] as? String != "error"
                else { continue }
                let reading = AgentContextUsage.parse(record.data, tool: .openCode, observedAt: record.time)
                if reading.lastResponse != nil { return reading }
            }
            return nil
        }
        return nil
    }
}
