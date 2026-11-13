import Foundation
import SQLite3
import Testing

@testable import AAYRA

struct AgentContextUsageTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func qwenUsesLastPromptRatherThanSessionTotalAndRecordedCapacity() {
        let value = AgentContextUsage.parse(
            data(
                """
                {"type":"assistant","model":"custom-qwen","contextWindowSize":10000,"usageMetadata":{"promptTokenCount":8000,"totalTokenCount":9000}}
                {"type":"assistant","model":"custom-qwen","contextWindowSize":10000,"usageMetadata":{"promptTokenCount":2000,"totalTokenCount":3000}}
                """), tool: .qwen)
        #expect(value.percent == 20)
        #expect(value.used == 2000)
        #expect(value.capacity == 10000)
    }

    @Test func kimiUsesNativeContextFractionAndPartialUpdates() {
        let value = AgentContextUsage.parse(
            data(
                """
                {"message":{"type":"StatusUpdate","payload":{"context_usage":0.7,"context_tokens":7000,"max_context_tokens":10000}}}
                {"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":999999}}}}
                """), tool: .kimi)
        #expect(value.percent == 70)
        #expect(value.used == 7000)
        #expect(value.capacity == 10000)
        #expect(
            AgentContextUsage.parse(
                data(
                    """
                    {"message":{"type":"StatusUpdate","payload":{"context_usage":0}}}
                    """), tool: .kimi
            ).percent == 0)
    }

    @Test(arguments: [AgentTool.pi, .ohMyPi])
    func piCountsLastResponseWithCacheAndHonorsModelConfiguration(_ tool: AgentTool) {
        let result = AgentContextUsage.parse(
            data(
                """
                {"type":"session","id":"session"}
                {"type":"message","id":"a","parentId":null,"message":{"role":"assistant","model":"custom","provider":"local","usage":{"input":8000,"output":1000,"cacheRead":2000,"cacheWrite":1000}}}
                {"type":"message","id":"b","parentId":"a","message":{"role":"assistant","model":"custom","provider":"local","usage":{"input":1000,"output":100,"cacheRead":800,"cacheWrite":100}}}
                """), tool: tool, limits: ["custom": 5000, "local/custom": 10000])
        #expect(result.used == 2000)
        #expect(result.percent == 20)
    }

    @Test func piDiscardsRewoundBranchAndClearsAfterCompaction() {
        let records = """
            {"type":"session","id":"s"}
            {"type":"message","id":"a","parentId":null,"message":{"role":"assistant","model":"custom","usage":{"input":1000}}}
            {"type":"message","id":"discarded","parentId":"a","message":{"role":"assistant","model":"custom","usage":{"input":9000}}}
            {"type":"message","id":"b","parentId":"a","message":{"role":"user"}}
            """
        #expect(AgentContextUsage.parse(data(records), tool: .pi, limits: ["custom": 10000]).percent == 10)
        let compacted = records + "\n" + #"{"type":"compaction","id":"c","parentId":"b","tokensBefore":1000}"#
        #expect(AgentContextUsage.parse(data(compacted), tool: .pi, limits: ["custom": 10000]).percent == nil)
    }

    @Test(arguments: [AgentTool.cline, .rooCode, .kiloCode])
    func extensionsUseOneRequestAndCorrectCacheSemantics(_ tool: AgentTool) throws {
        let request = #"{"tokensIn":4000,"tokensOut":500,"cacheReads":1000,"cacheWrites":500}"#
        let object: [[String: Any]] = [
            [
                "type": "say", "say": "api_req_started", "text": request,
                "modelInfo": ["modelId": "custom", "contextWindow": 10000],
            ]
        ]
        let result = AgentContextUsage.parse(try JSONSerialization.data(withJSONObject: object), tool: tool)
        #expect(result.percent == (tool == .cline ? 60 : 45))
    }

    @Test func cherryReadsProviderInputAndCacheRatherThanCumulativeSpend() {
        let result = AgentContextUsage.parse(
            data(
                """
                {"type":"assistant","message":{"model":"custom","usage":{"input_tokens":1000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":1000,"output_tokens":500}}}
                """), tool: .cherryStudio, limits: ["custom": 10000])
        #expect(result.used == 7500)
        #expect(result.percent == 75)
    }

    @Test func rpcAndProjectionSnapshotsHaveUsageSemantics() {
        let pi = AgentContextUsage.parse(
            data(
                """
                {"type":"response","success":true,"command":"get_session_stats","data":{"tokens":{"total":999999},"contextUsage":{"tokens":9000,"contextWindow":10000,"percent":90}}}
                """), tool: .pi)
        #expect(pi.percent == 90)
        let cherry = AgentContextUsage.parse(
            data(#"{"contextUsage":{"used":{"tokens":7000},"contextWindow":10000}}"#), tool: .cherryStudio)
        #expect(cherry.percent == 70)
        let zcode = AgentContextUsage.parse(data(#"{"contextWindow":{"usedTokens":8000,"maxTokens":10000}}"#), tool: .zcode)
        #expect(zcode.percent == 80)
    }

    @Test func unknownCapacityInvalidCountsAndPostCompactUnknownNeverBecomeZero() {
        for text in [
            #"{"type":"assistant","model":"unknown-model-123","usageMetadata":{"promptTokenCount":1000}}"#,
            #"{"type":"assistant","contextWindowSize":0,"usageMetadata":{"promptTokenCount":1000}}"#,
            #"{"type":"assistant","contextWindowSize":1000,"usageMetadata":{"promptTokenCount":-1}}"#,
            #"{"type":"assistant","contextWindowSize":1000,"usageMetadata":{"promptTokenCount":true}}"#,
        ] {
            #expect(AgentContextUsage.parse(data(text), tool: .qwen).percent == nil)
        }
        let value = AgentContextUsage.parse(
            data(
                """
                {"contextUsage":{"tokens":8000,"contextWindow":10000}}
                {"contextUsage":{"tokens":null,"contextWindow":10000,"percent":null}}
                """), tool: .pi)
        #expect(value.percent == nil)
    }

    @Test func geminiQuotaHandlesFullZeroExpiredAndInvalidBuckets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AgentAccountUsage.parseGeminiQuota(
            data(
                """
                {"buckets":[
                {"modelId":"gemini-pro","remainingFraction":1,"resetTime":1800003600,"tokenType":"REQUESTS"},
                {"modelId":"gemini-flash","remainingFraction":0,"remainingAmount":"0","resetTime":1800003600},
                {"modelId":"expired","remainingFraction":0.5,"resetTime":1700000000},
                {"modelId":"invalid","remainingFraction":1.5,"resetTime":1800003600},
                {"modelId":"boolean","remainingFraction":true,"resetTime":1800003600}]}
                """), now: now)
        #expect(result.count == 2)
        #expect(result.map(\.remainingPercent).compactMap { $0 }.sorted() == [0, 100])
        #expect(AgentTool.gemini.menuBarPercentageMeaning == .remaining)
    }

    @Test func bundledModelCapacityResolvesExactIdentityAndRejectsUnknowns() {
        #expect(AgentContextModels.capacity(model: "claude-sonnet-4-5", provider: "anthropic") == 200000)
        #expect(AgentContextModels.capacity(model: "unlisted-private-model-123", provider: "private") == nil)
    }

    @Test func diskReaderOnlyTouchesRequestedAgentsAndDoesNotReuseOldSessions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent(".qwen/projects/example/chats/session.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(#"{"type":"assistant","contextWindowSize":10000,"usageMetadata":{"promptTokenCount":7000}}"#).write(to: session)
        let paths = AgentPaths(home: home, environment: [:])
        let fresh = AgentContextUsage.read(for: [.qwen], paths: paths)
        #expect(fresh[.qwen]?.percent == 70)
        #expect(fresh[.kimi] == nil)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90000)], ofItemAtPath: session.path)
        #expect(AgentContextUsage.read(for: [.qwen], paths: paths)[.qwen]?.percent == nil)
    }

    @Test(arguments: [AgentTool.kiloCode, .zcode])
    func databaseReadersExtractUsageMetadataAndRespectKnownCapacity(_ tool: AgentTool) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(tool == .kiloCode ? ".local/share/kilo/kilo.db" : ".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        let database = try #require(db)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE message (data TEXT, time_created INTEGER)", nil, nil, nil) == SQLITE_OK)
        let json =
            #"{"role":"assistant","modelID":"custom","contextWindow":10000,"tokens":{"input":5000,"output":1000,"reasoning":0,"cache":{"read":1000,"write":0}}}"#
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        #expect(sqlite3_exec(database, "INSERT INTO message VALUES ('\(json)', \(milliseconds))", nil, nil, nil) == SQLITE_OK)
        let readings = AgentContextUsage.read(for: [tool], paths: AgentPaths(home: home, environment: [:]))
        #expect(readings[tool]?.percent == 70)
        #expect(readings[tool]?.used == 7000)
    }
}
