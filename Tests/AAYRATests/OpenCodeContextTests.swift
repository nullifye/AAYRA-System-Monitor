import Foundation
import SQLite3
import Testing

@testable import AAYRA

struct OpenCodeContextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    private let response = """
        {"model":{"id":"gpt-4o","providerID":"openai"},"finish":"stop","tokens":{"input":1000,"output":100,"reasoning":50,"cache":{"read":5000,"write":500}}}
        """

    private func withDatabase(_ body: (URL, OpaquePointer) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aayra-opencode-context-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        defer { sqlite3_close(handle) }
        try body(url, handle)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func createCurrent(_ db: OpaquePointer) {
        exec(
            db, "CREATE TABLE session_message(id TEXT, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT)")
    }

    @Test func currentSchemaReadsLastValidResponseWithModelProviderAndCacheBreakdown() throws {
        try withDatabase { url, db in
            createCurrent(db)
            exec(
                db,
                """
                INSERT INTO session_message VALUES('1','s','assistant',1,\(nowMs - 5000),'\(response)');
                INSERT INTO session_message VALUES('2','s','assistant',2,\(nowMs - 4000),'{"model":{"id":"gpt-4o","providerID":"openai"}}');
                INSERT INTO session_message VALUES('3','s','assistant',3,\(nowMs - 3000),'{"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
                INSERT INTO session_message VALUES('4','s','assistant',4,\(nowMs - 2000),'{"error":{"name":"Aborted"},"tokens":{"input":90000}}');
                INSERT INTO session_message VALUES('5','s','assistant',5,\(nowMs - 1000),'{"finish":"error","tokens":{"input":90000}}');
                """)
            let reading = try #require(OpenCodeContext.read(database: url, now: now))
            #expect(reading.model == "gpt-4o")
            #expect(reading.provider == "openai")
            #expect(reading.used == 6650)
            #expect(reading.capacity == 128000)
            #expect(reading.percent == Double(6650) / 128000 * 100)
            #expect(reading.observedAt == now.addingTimeInterval(-5))
            #expect(reading.lastResponse == TokenTally(input: 1000, output: 100, reasoning: 50, cacheRead: 5000, cacheWrite: 500))
        }
    }

    @Test func newSessionCannotInheritAnotherSessionsContext() throws {
        try withDatabase { url, db in
            createCurrent(db)
            exec(
                db,
                """
                INSERT INTO session_message VALUES('1','old','assistant',1,\(nowMs - 2000),'\(response)');
                INSERT INTO session_message VALUES('2','new','user',1,\(nowMs - 1000),'{}');
                """)
            #expect(OpenCodeContext.read(database: url, now: now) == nil)
        }
    }

    @Test(arguments: ["compaction", "model-switched"])
    func boundariesInvalidateOldContextUntilAnotherResponse(_ type: String) throws {
        try withDatabase { url, db in
            createCurrent(db)
            exec(
                db,
                """
                INSERT INTO session_message VALUES('1','s','assistant',1,\(nowMs - 3000),'\(response)');
                INSERT INTO session_message VALUES('2','s','\(type)',2,\(nowMs - 2000),'{}');
                INSERT INTO session_message VALUES('3','s','assistant',3,\(nowMs - 1000),'{"tokens":{"input":0}}');
                """)
            let waiting = try #require(OpenCodeContext.read(database: url, now: now))
            #expect(waiting.percent == nil)
            #expect(waiting.lastResponse == nil)
            #expect(waiting.detail.contains("Waiting"))
            exec(db, "INSERT INTO session_message VALUES('4','s','assistant',4,\(nowMs),'\(response)')")
            #expect(OpenCodeContext.read(database: url, now: now)?.used == 6650)
        }
    }

    @Test func unknownModelKeepsCountsWithoutInventingCapacity() throws {
        try withDatabase { url, db in
            createCurrent(db)
            exec(
                db,
                """
                INSERT INTO session_message VALUES('1','s','assistant',1,\(nowMs),'{"model":{"id":"unlisted-private-model-123","providerID":"private"},"tokens":{"input":10,"cache":{"read":90}}}');
                """)
            let reading = try #require(OpenCodeContext.read(database: url, now: now))
            #expect(reading.percent == nil)
            #expect(reading.capacity == nil)
            #expect(reading.used == 100)
            #expect(reading.provider == "private")
            #expect(reading.lastResponse?.cacheReusePercent == 90)
        }
    }

    @Test(arguments: [Int64(-90_000_000), Int64(120_000)])
    func staleAndFutureReadingsAreUnavailable(_ offset: Int64) throws {
        try withDatabase { url, db in
            createCurrent(db)
            exec(db, "INSERT INTO session_message VALUES('1','s','assistant',1,\(nowMs + offset),'\(response)')")
            #expect(OpenCodeContext.read(database: url, now: now) == nil)
        }
    }

    @Test func legacySchemaWorksWithAnEmptyNewTableAndClearsAfterSummary() throws {
        try withDatabase { url, db in
            createCurrent(db)
            exec(
                db,
                """
                CREATE TABLE message(session_id TEXT, time_created INTEGER, data TEXT);
                INSERT INTO message VALUES('s',\(nowMs - 2000),'{"role":"assistant","modelID":"gpt-4o","providerID":"openai","tokens":{"input":1000,"output":100,"cache":{"read":500}}}');
                """)
            #expect(OpenCodeContext.read(database: url, now: now)?.used == 1600)
            exec(db, "INSERT INTO message VALUES('s',\(nowMs - 1000),'{\"role\":\"assistant\",\"summary\":true}')")
            #expect(OpenCodeContext.read(database: url, now: now)?.percent == nil)
        }
    }

    @Test func cacheReuseUsesAllPromptInputAndNothingElse() {
        #expect(
            TokenTally(input: 1000, output: 99999, reasoning: 99999, cacheRead: 5000, cacheWrite: 500).cacheReusePercent
                == Double(5000) / 6500 * 100)
        #expect(TokenTally(input: 50).cacheReusePercent == 0)
        #expect(TokenTally(cacheRead: 50).cacheReusePercent == 100)
        #expect(TokenTally(output: 50, reasoning: 50, unclassified: 50).cacheReusePercent == nil)
        #expect(TokenTally().cacheReusePercent == nil)
    }

    @Test func contextNeverSubstitutesForAccountAllowance() {
        #expect(AgentTool.openCode.readsLocalContext)
        #expect(AgentTool.openCode.menuBarPercentageMeaning == .remaining)
        #expect(AgentTool.openCode.displayedPercent(allowance: 41, context: 60) == 41)
        #expect(AgentTool.openCode.displayedPercent(allowance: nil, context: 60) == nil)
        #expect(AgentTool.kiloCode.displayedPercent(allowance: 41, context: 60) == 60)
        #expect(AgentTool.kiloCode.displayedPercent(allowance: 41, context: nil) == nil)
    }
}
