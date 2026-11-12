import Foundation
import SQLite3
import Testing

@testable import AAYRA

struct AgentUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var today: DateInterval { DateInterval(start: Calendar.current.startOfDay(for: now), duration: 86_400) }
    private var stamp: String { ISO8601DateFormatter().string(from: now) }
    private var yesterday: String {
        ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: now).addingTimeInterval(-60))
    }
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }

    @Test func menuBarSelectionLimitsAgentsAndPreservesSelectionOrder() {
        #expect(
            AgentMenuBarSelection.validated(["codex", "claude", "copilot", "openCode", "perch"]) == [.codex, .claude, .copilot])
        #expect(AgentMenuBarSelection.validated([]).isEmpty)
    }

    @Test func menuBarSelectionDropsDuplicatesUnknownAgentsAndTokenOnlyAgents() {
        #expect(
            AgentMenuBarSelection.validated(["unknown", "gemini", "codex", "codex", "pi", "perch", "claude"])
                == [.codex, .perch, .claude])
    }

    @Test func menuBarPercentUsesTightestValidAllowanceIncludingZero() {
        func status(_ percentages: [Double?]) -> AgentUsageStatus {
            .init(
                kind: .codex,
                allowances: percentages.enumerated().map {
                    .init(name: "Window \($0.offset)", remaining: "", resetsAt: now, remainingPercent: $0.element)
                }, detail: "", checkedAt: now)
        }
        #expect(status([72, 41, nil]).menuBarRemainingPercent == 41)
        #expect(status([72, 0]).menuBarRemainingPercent == 0)
        #expect(status([nil, .nan, .infinity, -1, 101]).menuBarRemainingPercent == nil)
        #expect(AgentUsageStatus.unavailable(.codex, "Unavailable").menuBarRemainingPercent == nil)
    }

    @Test func codexOnlyAcceptsRecentRateLimitEvents() throws {
        let observed = ISO8601DateFormatter().string(from: now)
        let text = """
            {"type":"event_msg","timestamp":"\(observed)","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":27.4,"window_minutes":300,"resets_at":1800003600},"secondary":{"used_percent":50,"window_minutes":10080,"resets_at":1800086400}}}}
            """
        let values = AgentUsageProvider.parseCodex(Data(text.utf8), now: now)
        #expect(values.map(\.name) == ["5-hour", "Weekly"])
        #expect(values.map(\.remaining) == ["73% remaining", "50% remaining"])
        #expect(values.map(\.remainingPercent) == [72.6, 50])
        #expect(AgentUsageProvider.parseCodex(Data(text.utf8), now: now.addingTimeInterval(901)).isEmpty)
    }

    @Test func codexRejectsMissingAndExpiredSnapshots() {
        let text = """
            {"type":"event_msg","timestamp":"2027-01-15T08:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":100}}}}
            """
        #expect(AgentUsageProvider.parseCodex(Data(text.utf8), now: now).isEmpty)
    }

    @Test func openCodeDistinguishesLimitsAndMissingAccount() {
        #expect(AgentUsageProvider.parseOpenCode(Data("{\"data\":null}".utf8), now: now).isEmpty)
        let text = """
            {"data":{"go":{"rolling":{"percent":30,"limited":true,"resetsAt":1800003600000},"weekly":{"percent":0,"limited":false,"resetsAt":1800086400000}},"budgets":[{"id":"Credit","limit":10,"spent":3,"resetsAt":1800086400000}]}}
            """
        let values = AgentUsageProvider.parseOpenCode(Data(text.utf8), now: now)
        #expect(values.map(\.name) == ["Rolling", "Credit"])
        #expect(values.map(\.remaining) == ["70% remaining", "$7.00 of $10.00 remaining"])
        #expect(values.map(\.remainingPercent) == [70, 70])
    }

    @Test func claudeOAuthWindowsRejectAbsentOrInvalidValues() {
        let payload = """
            {"five_hour":{"utilization":24.6,"resets_at":"2027-01-15T09:00:00.000Z"},"seven_day":{"utilization":150,"resets_at":"2027-01-16T08:00:00Z"}}
            """
        let windows = AgentAccountUsage.parseClaude(Data(payload.utf8), now: now)
        #expect(windows.map(\.name) == ["5-hour"])
        #expect(windows.map(\.remaining) == ["75% remaining"])
        #expect(AgentAccountUsage.parseClaude(Data("{}".utf8), now: now).isEmpty)
    }

    @Test func codexLiveUsageIgnoresAdditionalBucketsAndExpiredWindows() {
        let payload = """
            {"rate_limit":{"primary_window":{"used_percent":20,"reset_at":1800003600,"limit_window_seconds":18000},"secondary_window":{"used_percent":40,"reset_at":100,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"Other"}]}
            """
        let windows = AgentAccountUsage.parseCodexUsage(Data(payload.utf8), now: now)
        #expect(windows.map(\.name) == ["5-hour"])
        #expect(windows.map(\.remaining) == ["80% remaining"])
        #expect(AgentAccountUsage.parseCodexUsage(Data("{\"rate_limit\":null}".utf8), now: now).isEmpty)
    }

    @Test func signInFailuresOfferRecoveryWithoutResponseContent() {
        #expect(AgentAccountUsage.httpFailure(200) == nil)
        #expect(AgentAccountUsage.httpFailure(401)?.contains("sign in again") == true)
        #expect(AgentAccountUsage.httpFailure(403)?.contains("access denied") == true)
        #expect(AgentAccountUsage.httpFailure(429)?.contains("rate-limited") == true)
        #expect(AgentAccountUsage.httpFailure(503) == "Usage service returned HTTP 503")
    }

    @Test func openCodeGoRequiresSpecificApiCredentialAndCompleteServerWindows() {
        let auth = Data("{\"opencode\":{\"type\":\"api\",\"key\":\"zen\"}}".utf8)
        #expect(AgentAccountUsage.parseOpenCodeGoKey(auth) == nil)
        #expect(
            AgentAccountUsage.parseOpenCodeGoKey(Data("{\"opencode-go\":{\"type\":\"oauth\",\"key\":\"wrong\"}}".utf8)) == nil)
        #expect(
            AgentAccountUsage.parseOpenCodeGoKey(Data("{\"opencode-go\":{\"type\":\"api\",\"key\":\"test-key\"}}".utf8))
                == "test-key")
        let usage = """
            {"usage":{"rolling":{"percent":12,"resetsAt":"2027-01-15T09:00:00Z"},"weekly":{"percent":44,"resetsAt":"2027-01-16T08:00:00Z"}}}
            """
        let windows = AgentAccountUsage.parseOpenCodeGo(Data(usage.utf8), now: now)
        #expect(windows.map(\.remaining) == ["88% remaining", "56% remaining"])
        #expect(AgentAccountUsage.parseOpenCodeGo(Data("{\"usage\":{\"rolling\":{\"percent\":12}}}".utf8), now: now).isEmpty)
    }

    @Test func copilotRequiresServerQuotaAndResetRatherThanLocalTokens() {
        let payload = """
            {"quota_reset_date":"2027-01-20","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":30},"chat":{"percent_remaining":80}}}
            """
        let windows = AgentAccountUsage.parseCopilot(Data(payload.utf8), now: now)
        #expect(windows.map(\.name) == ["Premium", "Chat"])
        #expect(windows.map(\.remaining) == ["30% remaining", "80% remaining"])
        #expect(AgentAccountUsage.parseCopilot(Data("{\"tokens\":1000}".utf8), now: now).isEmpty)
    }

    @Test func panelOnlyScrollsWhenContentExceedsDisplay() {
        #expect(AgentUsageLayout.height(for: 580, available: 800) == 580)
        #expect(!AgentUsageLayout.needsScroll(content: 580, available: 800))
        #expect(AgentUsageLayout.height(for: 900, available: 700) == 700)
        #expect(AgentUsageLayout.needsScroll(content: 900, available: 700))
    }

    @Test func claudeLocalTokensDeduplicateMessageIDsAndExcludeOtherDays() {
        let day = Calendar.current.startOfDay(for: now)
        let stamp = ISO8601DateFormatter().string(from: now)
        let older = ISO8601DateFormatter().string(from: day.addingTimeInterval(-60))
        let line = """
            {"type":"assistant","timestamp":"\(stamp)","message":{"id":"msg-1","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":3,"cache_read_input_tokens":2}}}
            """
        let old = """
            {"type":"assistant","timestamp":"\(older)","message":{"id":"msg-old","usage":{"input_tokens":999,"output_tokens":1}}}
            """
        var largest: [String: AgentLocalTokens.Snapshot] = [:]
        AgentLocalTokens.claudeTokens(Data("\(old)\n\(line)\n\(line)\n".utf8), day: today, into: &largest)
        #expect(largest.values.reduce(0) { $0 + $1.tally.total } == 20)
    }

    @Test func codexLocalTokensUseCumulativeDeltasRatherThanDoubleCounting() {
        let day = Calendar.current.startOfDay(for: now)
        let old = ISO8601DateFormatter().string(from: day.addingTimeInterval(-60))
        let recent = ISO8601DateFormatter().string(from: now)
        func event(_ stamp: String, _ count: Int) -> String {
            """
            {"type":"event_msg","timestamp":"\(stamp)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(count)},"last_token_usage":{"total_tokens":999}}}}
            """
        }
        let lines = [event(old, 1_000), event(recent, 1_200), event(recent, 1_200), event(recent, 1_300)].joined(separator: "\n")
        #expect(AgentLocalTokens.codexTokens(Data(lines.utf8), day: today).total == 300)
    }

    @Test func openCodeLocalTokensReadAssistantMetadataOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aayra-agent-tokens-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        guard let db else { return }
        let stamp = Int64(now.timeIntervalSince1970 * 1_000)
        let sql = """
            CREATE TABLE session_message(type TEXT, time_created INTEGER, data TEXT);
            INSERT INTO session_message VALUES('assistant',\(stamp),'{"tokens":{"input":10,"output":5,"cache":{"read":2,"write":3},"reasoning":4}}');
            INSERT INTO session_message VALUES('user',\(stamp),'{"tokens":{"input":999}}');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        // input + output + reasoning + cache read + cache write; the user row is ignored.
        #expect(AgentLocalTokens.openCodeTokens(database: url, day: today)?.total == 24)
    }

    @Test func copilotChatLogAppliesSnapshotAppendsAndTokenUpdates() {
        let todayMs = nowMs
        let yesterdayMs = Int64(today.start.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        let lines = [
            #"{"kind":0,"v":{"requests":[{"timestamp":\#(yesterdayMs),"promptTokens":900,"completionTokens":90}]}}"#,
            #"{"kind":2,"k":["requests"],"v":[{"timestamp":\#(todayMs),"message":{"text":"hi"}}]}"#,
            #"{"kind":1,"k":["requests",1,"promptTokens"],"v":100}"#,
            #"{"kind":1,"k":["requests",1,"completionTokens"],"v":10}"#,
            #"{"kind":1,"k":["requests",1,"promptTokens"],"v":120}"#,
            #"{"kind":2,"k":["requests"],"v":[{"timestamp":\#(todayMs),"promptTokens":5,"completionTokens":1}]}"#,
            #"{"kind":2,"k":["requests"],"i":2,"v":[{"timestamp":\#(todayMs),"promptTokens":7,"completionTokens":3}]}"#,
            #"{"kind":1,"k":["requests",9,"promptTokens"],"v":999}"#,
            "not json",
        ].joined(separator: "\n")
        // 120 + 10 for the edited request, then the truncate-and-append replaces 5 + 1 with 7 + 3.
        #expect(AgentLocalTokens.copilotTokens(Data(lines.utf8), day: today).total == 140)
    }

    @Test func agentChoicesDefaultToAccountsAndDetectedTools() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aayra-agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AgentPaths(home: home, environment: [:])
        #expect(AgentTool.detectedOnThisMac(paths).isEmpty)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        #expect(AgentTool.detectedOnThisMac(paths) == [.codex])
        let custom = AgentPaths(home: home, environment: ["CODEX_HOME": "/elsewhere"])
        #expect(custom.codex.path == "/elsewhere")
    }

    @Test func claudeFormatKeepsLargestStreamSnapshotPerRequest() {
        // Cherry Studio writes one API call several times while streaming; only the final size counts.
        let lines = [
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":10,"output_tokens":1}}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":10,"output_tokens":30}}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"r2","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":99,"output_tokens":1}}}"#,
        ].joined(separator: "\n")
        var largest: [String: AgentLocalTokens.Snapshot] = [:]
        AgentLocalTokens.claudeTokens(Data(lines.utf8), day: today, into: &largest)
        #expect(largest.values.reduce(0) { $0 + $1.tally.total } == 40)
    }

    @Test func geminiReadsJSONAndJSONLRecordingsWithLastCopyWinning() {
        let json = """
            {"sessionId":"s","messages":[
              {"id":"a","timestamp":"\(stamp)","type":"user"},
              {"id":"b","timestamp":"\(stamp)","type":"gemini","model":"g","tokens":{"input":100,"output":20,"cached":50,"thoughts":5,"tool":0,"total":125}},
              {"id":"c","timestamp":"\(yesterday)","type":"gemini","model":"g","tokens":{"total":999}}]}
            """
        #expect(AgentLocalTokens.geminiTokens(Data(json.utf8), day: today).total == 125)
        let jsonl = [
            #"{"sessionId":"s"}"#,
            #"{"id":"b","timestamp":"\#(stamp)","type":"gemini","tokens":{"input":10,"output":1}}"#,
            #"{"id":"b","timestamp":"\#(stamp)","type":"gemini","tokens":{"input":10,"output":4,"thoughts":2}}"#,
        ].joined(separator: "\n")
        #expect(AgentLocalTokens.geminiTokens(Data(jsonl.utf8), day: today).total == 16)
    }

    @Test func qwenUsesReportedTotalElseParts() {
        let lines = [
            #"{"type":"assistant","timestamp":"\#(stamp)","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":10,"totalTokenCount":110}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp)","usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"thoughtsTokenCount":1}}"#,
            #"{"type":"user","timestamp":"\#(stamp)","usageMetadata":{"totalTokenCount":999}}"#,
            #"{"type":"assistant","timestamp":"\#(yesterday)","usageMetadata":{"totalTokenCount":999}}"#,
        ].joined(separator: "\n")
        #expect(AgentLocalTokens.qwenTokens(Data(lines.utf8), day: today).total == 118)
    }

    @Test func extensionTasksCountRequestsAndRespectGrossInput() throws {
        func event(_ request: String, ts: Int64) -> [String: Any] {
            ["type": "say", "say": "api_req_started", "ts": ts, "text": request]
        }
        let request = #"{"tokensIn":100,"tokensOut":10,"cacheReads":40,"cacheWrites":5}"#
        let events: [[String: Any]] = [
            event(request, ts: nowMs),
            ["type": "say", "say": "text", "ts": nowMs, "text": "hello"],
            event(request, ts: nowMs - 86_400_000),
        ]
        let data = try JSONSerialization.data(withJSONObject: events)
        // Cline: tokensIn excludes cache, so cache is added. Roo/Kilo (after Nov 2025): tokensIn already includes it.
        #expect(AgentLocalTokens.extensionTaskTokens(data, day: today, grossInput: { _, _ in false }).total == 155)
        #expect(AgentLocalTokens.extensionTaskTokens(data, day: today, grossInput: { _, _ in true }).total == 110)
        let cli = """
            {"messages":[{"role":"user","ts":\(nowMs)},{"role":"assistant","ts":\(nowMs),"metrics":{"inputTokens":50,"outputTokens":7,"cacheReadTokens":30}}]}
            """
        #expect(AgentLocalTokens.clineCLITokens(Data(cli.utf8), day: today).total == 57)
    }

    @Test func kimiCountsTurnRecordsAndLargestLegacySnapshot() {
        let seconds = now.timeIntervalSince1970
        let lines = [
            #"{"type":"usage.record","usageScope":"turn","time":\#(nowMs),"usage":{"inputOther":10,"output":5,"inputCacheRead":3,"inputCacheCreation":2}}"#,
            #"{"type":"usage.record","usageScope":"step","time":\#(nowMs),"usage":{"inputOther":99}}"#,
            #"{"timestamp":\#(seconds),"message":{"type":"StatusUpdate","payload":{"message_id":"m","token_usage":{"input_other":4,"output":1}}}}"#,
            #"{"timestamp":\#(seconds),"message":{"type":"StatusUpdate","payload":{"message_id":"m","token_usage":{"input_other":4,"output":6}}}}"#,
        ].joined(separator: "\n")
        #expect(AgentLocalTokens.kimiTokens(Data(lines.utf8), day: today).total == 30)
    }

    @Test func piDeduplicatesForkedRepliesAcrossFiles() {
        let file = [
            #"{"type":"session","id":"s"}"#,
            #"{"type":"message","id":"e1","timestamp":"\#(stamp)","message":{"role":"assistant","responseId":"r1","model":"m","usage":{"input":10,"output":5,"cacheRead":20,"cacheWrite":1,"reasoning":3}}}"#,
            #"{"type":"message","id":"e2","timestamp":"\#(stamp)","message":{"role":"user","usage":{"input":999}}}"#,
        ].joined(separator: "\n")
        var largest: [String: AgentLocalTokens.Snapshot] = [:]
        AgentLocalTokens.piTokens(Data(file.utf8), day: today, into: &largest)
        AgentLocalTokens.piTokens(Data(file.utf8), day: today, into: &largest)  // a fork copies the reply
        #expect(largest.values.reduce(0) { $0 + $1.tally.total } == 36)
        var ignored: [String: AgentLocalTokens.Snapshot] = [:]
        AgentLocalTokens.piTokens(
            Data(file.split(separator: "\n").dropFirst().joined(separator: "\n").utf8), day: today, into: &ignored)
        #expect(ignored.isEmpty)
    }

    @Test func kiloCLIUsesOpenCodeMessageSchema() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aayra-kilo-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        guard let db else { return }
        let sql = """
            CREATE TABLE message(id TEXT, session_id TEXT, data TEXT);
            INSERT INTO message VALUES('1','s','{"role":"assistant","modelID":"m","time":{"created":\(nowMs)},"tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}}}');
            INSERT INTO message VALUES('2','s','{"role":"assistant","modelID":"m","time":{"created":\(nowMs - 86_400_000)},"tokens":{"input":999}}');
            INSERT INTO message VALUES('3','s','{"role":"user","time":{"created":\(nowMs)},"tokens":{"input":999}}');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(AgentLocalTokens.openCodeTokens(database: url, day: today)?.total == 15)
    }

    @Test func todayOnlyReadsRequestedAgents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aayra-today-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let chats = home.appendingPathComponent(".qwen/projects/p/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let line =
            #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","usageMetadata":{"totalTokenCount":42}}"#
        try Data(line.utf8).write(to: chats.appendingPathComponent("s.jsonl"))
        let paths = AgentPaths(home: home, environment: [:])
        #expect(AgentLocalTokens.today(for: [.qwen], paths: paths)[.qwen]?.total == 42)
        #expect(AgentLocalTokens.today(for: [.claude], paths: paths).isEmpty)
    }

    @Test func accountRequestsArePacedAndReuseTheLastResult() async {
        let gate = AgentUsageThrottle()
        #expect(await gate.admit(.claude, now: now) == .request)
        let good = AgentUsageStatus(
            kind: .claude,
            allowances: [.init(name: "5-hour", remaining: "", resetsAt: now.addingTimeInterval(3_600), remainingPercent: 70)],
            detail: "", checkedAt: now)
        await gate.record(good)
        // Reopening the panel or pressing Refresh inside the interval sends nothing.
        #expect(await gate.admit(.claude, now: now.addingTimeInterval(299)) == .reuse(good))
        #expect(await gate.admit(.claude, now: now.addingTimeInterval(301)) == .request)
        #expect(await gate.admit(.codex, now: now) == .request)
        #expect(await gate.admit(.codex, now: now.addingTimeInterval(121)) == .request)
    }

    @Test func rateLimitKeepsShowingLastGoodWindowsUntilTheyReset() async {
        let gate = AgentUsageThrottle()
        let good = AgentUsageStatus(
            kind: .codex,
            allowances: [
                .init(name: "5-hour", remaining: "", resetsAt: now.addingTimeInterval(600), remainingPercent: 40),
                .init(name: "Weekly", remaining: "", resetsAt: now.addingTimeInterval(86_400), remainingPercent: 80),
            ], detail: "", checkedAt: now)
        await gate.record(good)
        let retry = await gate.rateLimited(.codex, retryAfter: nil, now: now)
        guard case .throttled(let until) = await gate.admit(.codex, now: now.addingTimeInterval(60)) else {
            Issue.record("expected throttled")
            return
        }
        #expect(until == retry)
        let stale = await gate.stale(.codex, now: now.addingTimeInterval(900), reason: "Busy")
        #expect(stale?.allowances.map(\.name) == ["Weekly"])  // the 5-hour window has reset since
        #expect(stale?.detail.hasPrefix("Busy · showing values from") == true)
        #expect(await gate.stale(.claude, now: now, reason: "Busy") == nil)
    }

    @Test func codexSplitsTokenTypesAndModelsFromRunningTotals() {
        func usage(_ input: Int, cached: Int, output: Int, reasoning: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}}}}"#
        }
        let lines = [
            #"{"type":"turn_context","payload":{"model":"gpt-5"}}"#,
            usage(1_000, cached: 800, output: 100, reasoning: 40),
            #"{"type":"turn_context","payload":{"model":"gpt-5-mini"}}"#,
            usage(1_500, cached: 1_200, output: 160, reasoning: 60),
        ].joined(separator: "\n")
        let result = AgentLocalTokens.codexTokens(Data(lines.utf8), day: today)
        #expect(result.total == 1_660)
        #expect(result.byModel["gpt-5"] == TokenTally(input: 200, output: 60, reasoning: 40, cacheRead: 800))
        // The second turn's share is the growth of each running total.
        #expect(result.byModel["gpt-5-mini"] == TokenTally(input: 100, output: 40, reasoning: 20, cacheRead: 400))
    }

    @Test func claudeUsageIsGroupedByModelAndType() {
        let lines = [
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"a","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":5,"output_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"b","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        ].joined(separator: "\n")
        var largest: [String: AgentLocalTokens.Snapshot] = [:]
        AgentLocalTokens.claudeTokens(Data(lines.utf8), day: today, into: &largest)
        var result = AgentTokenUsage()
        for snapshot in largest.values { result.add(snapshot.tally, model: snapshot.model) }
        #expect(result.byModel["claude-opus-4-5"] == TokenTally(input: 5, output: 10, cacheRead: 100, cacheWrite: 20))
        #expect(result.byModel["claude-haiku-4-5"]?.total == 3)
        #expect(result.tally.cacheRead == 100)
    }

    @Test func modelNamesDropProviderPrefixesAndDates() {
        #expect(AgentTokenUsage.modelName("copilot/gpt-4.1") == "gpt-4.1")
        #expect(AgentTokenUsage.modelName("claude-sonnet-4-5-20250929") == "claude-sonnet-4-5")
        #expect(AgentTokenUsage.modelName(nil) == "Unknown")
        #expect(AgentTokenUsage.modelName("  ") == "Unknown")
    }

    @Test func tokensAreGroupedByWorkingFolder() {
        let claude = [
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"a","cwd":"/Users/me/app","message":{"model":"m","usage":{"input_tokens":5,"output_tokens":5}}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"b","cwd":"/Users/me/site/","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"c","message":{"model":"m","usage":{"input_tokens":3,"output_tokens":0}}}"#,
        ].joined(separator: "\n")
        var largest: [String: AgentLocalTokens.Snapshot] = [:]
        AgentLocalTokens.claudeTokens(Data(claude.utf8), day: today, into: &largest)
        var usage = AgentTokenUsage()
        for snapshot in largest.values { usage.add(snapshot.tally, model: snapshot.model, project: snapshot.project) }
        #expect(usage.byProject == ["/Users/me/app": 10, "/Users/me/site": 2])
        #expect(usage.total == 15)  // the folderless request still counts toward the total

        let codex = [
            #"{"type":"turn_context","payload":{"model":"gpt-5","cwd":"/Users/me/api"}}"#,
            #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":70,"output_tokens":30,"total_tokens":100}}}}"#,
        ].joined(separator: "\n")
        #expect(AgentLocalTokens.codexTokens(Data(codex.utf8), day: today).byProject == ["/Users/me/api": 100])
        #expect(AgentTokenUsage.projectPath("file:///Users/me/My%20App") == "/Users/me/My App")
        #expect(AgentTokenUsage.projectPath("relative/path") == nil)
    }

    @Test func claudeAccountShowsScopedWeeklyLimitsAndUsageCredits() {
        let reset = "2027-01-15T09:00:00Z"
        let payload = """
            {"seven_day":{"utilization":40,"resets_at":"\(reset)"},
             "limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"utilization":25,"resets_at":"\(reset)"},
                       {"kind":"other","utilization":99,"resets_at":"\(reset)"}],
             "extra_usage":{"is_enabled":true,"used_credits":235,"monthly_limit":2000,"decimal_places":2,"currency":"usd"}}
            """
        #expect(AgentAccountUsage.parseClaude(Data(payload.utf8), now: now).map(\.name) == ["Weekly", "Fable weekly"])
        // Currency formatting follows the Mac's region ("$2.35" or "US$2.35"), so check the amounts.
        let credits = AgentAccountUsage.parseClaudeFacts(Data(payload.utf8), now: now)
        #expect(credits.map(\.label) == ["Usage credits"])
        #expect(credits.first.map { $0.value.contains("2.35 of") && $0.value.contains("20.00 used") } == true)
        #expect(
            AgentAccountUsage.parseClaudeFacts(Data(#"{"extra_usage":{"is_enabled":false,"used_credits":0}}"#.utf8), now: now)
                .isEmpty)
    }

    @Test func codexAccountShowsPlanAndMeteredFeatureLimits() {
        let payload = """
            {"plan_type":"plus","rate_limit":{},"additional_rate_limits":[
              {"limit_name":"code_review","rate_limit":{"primary_window":{"used_percent":20,"reset_at":1800003600,"limit_window_seconds":604800}}}]}
            """
        let facts = AgentAccountUsage.parseCodexFacts(Data(payload.utf8), now: now)
        #expect(facts.map(\.label) == ["Plan", "Code Review · weekly"])
        #expect(facts.first?.value == "Plus")
        #expect(facts.last?.value.hasPrefix("80% left · resets") == true)
    }

    @Test func copilotAccountShowsRequestCountsAndUnlimitedFeatures() {
        let payload = """
            {"copilot_plan":"individual_pro","quota_snapshots":{
              "premium_interactions":{"entitlement":300,"remaining":212,"unlimited":false},
              "chat":{"unlimited":true},"completions":{"unlimited":true}}}
            """
        #expect(
            AgentAccountUsage.parseCopilotFacts(Data(payload.utf8), now: now) == [
                .init(label: "Plan", value: "Individual Pro"), .init(label: "Premium requests", value: "212 of 300 left"),
                .init(label: "Chat", value: "Unlimited"), .init(label: "Code completions", value: "Unlimited"),
            ])
    }

    @Test func defaultSelectionIsTheFirstThreeAgentsFoundOnThisMac() {
        #expect(
            AgentTool.defaultSelection(detected: [.zcode, .codex, .gemini, .claude, .openCode]) == [.claude, .codex, .openCode])
        #expect(AgentTool.defaultSelection(detected: [.qwen]) == [.qwen])
        #expect(AgentTool.defaultSelection(detected: [.perch]) == [.perch])
        // Perch stays selected when it has threads, even though it is last in the built-in order.
        #expect(
            AgentTool.defaultSelection(detected: [.claude, .codex, .gemini, .openCode, .perch])
                == [.claude, .codex, .openCode, .perch])
        #expect(AgentTool.defaultSelection(detected: []).isEmpty)
    }

    @Test func perchIsDetectedByItsThreadFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aayra-perch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AgentPaths(home: home, environment: [:])
        try FileManager.default.createDirectory(at: paths.perchThreads, withIntermediateDirectories: true)
        #expect(AgentTool.detectedOnThisMac(paths) == [.perch])
        #expect(AgentLocalTokens.today(for: [.perch], paths: paths).isEmpty)  // context fill, not a token ledger
    }

    @Test func savedOrderDropsUnknownIdsAndAppendsNewAgents() {
        let order = AgentTool.ordered(["zcode", "nope", "claude", "zcode"])
        #expect(Array(order.prefix(2)) == [.zcode, .claude])
        #expect(order.count == AgentTool.allCases.count)
        #expect(Set(order) == Set(AgentTool.allCases))
    }

    @Test func movingAnAgentPlacesItBeforeTheTarget() {
        let order: [AgentTool] = [.claude, .codex, .perch, .openCode]
        #expect(AgentTool.moved(.openCode, before: .claude, in: order) == [.openCode, .claude, .codex, .perch])
        #expect(AgentTool.moved(.claude, before: .perch, in: order) == [.codex, .claude, .perch, .openCode])
        #expect(AgentTool.moved(.codex, before: .codex, in: order) == order)
        #expect(AgentTool.moved(.claude, before: .zcode, in: order) == order)
    }

    @Test func perchReadsContextFillRatherThanTokens() {
        let payload = """
            {"version":1,"threadId":"cli-cwd-abc","updatedAt":"2027-01-15T08:00:00.000Z",
             "contextSnapshot":{"totalContextTokens":45000,"contextLimitTokens":180000,
               "modelLabel":"Standard","turnApiUsage":{"inputTokens":455,"outputTokens":3,"cacheReadInputTokens":25216},
               "contextCategories":[{"label":"System prompt","tokens":8708},{"label":"Tools","tokens":12999}]},
             "threadSession":{"lastObjective":"  Audit   March invoices  "}}
            """
        let thread = PerchContext.parse(Data(payload.utf8))
        #expect(thread?.id == "cli-cwd-abc")
        #expect(thread?.usedTokens == 45_000)
        #expect(thread?.limitTokens == 180_000)
        #expect(thread?.percent == 25)
        #expect(thread?.model == "Standard")
        // Whitespace is collapsed so a pasted prompt can't stretch the card.
        #expect(thread?.objective == "Audit March invoices")
        #expect(thread?.lastTurn == TokenTally(input: 455, output: 3, cacheRead: 25_216))
        // Largest section first.
        #expect(thread?.sections.map(\.name) == ["Tools", "System prompt"])
    }

    @Test func perchRejectsSnapshotsWithoutAWindowOrVersion() {
        // No limit: a share can't be computed, so the thread is skipped rather than shown as 0%.
        let noLimit = """
            {"version":1,"threadId":"t","contextSnapshot":{"totalContextTokens":45000}}
            """
        #expect(PerchContext.parse(Data(noLimit.utf8)) == nil)
        let wrongVersion = """
            {"version":2,"threadId":"t","contextSnapshot":{"totalContextTokens":1,"contextLimitTokens":2}}
            """
        #expect(PerchContext.parse(Data(wrongVersion.utf8)) == nil)
        #expect(PerchContext.parse(Data("not json".utf8)) == nil)
    }

    @Test func perchThreadsAreReadNewestFirstAndHonourTheOverride() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aayra-perch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AgentPaths(home: home, environment: [:])
        #expect(PerchContext.threads(paths: paths).isEmpty)
        let folder = paths.perchThreads.appendingPathComponent("user-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ stamp: String, _ used: Int) throws {
            let text = """
                {"version":1,"threadId":"\(name)","updatedAt":"\(stamp)",
                 "contextSnapshot":{"totalContextTokens":\(used),"contextLimitTokens":1000}}
                """
            try Data(text.utf8).write(to: folder.appendingPathComponent("\(name).json"))
        }
        try write("older", "2027-01-14T08:00:00.000Z", 100)
        try write("newer", "2027-01-15T08:00:00.000Z", 900)
        #expect(PerchContext.threads(paths: paths).map(\.id) == ["newer", "older"])
        let custom = AgentPaths(home: home, environment: ["PERCH_CLI_STATE_DIR": "/elsewhere"])
        #expect(custom.perchThreads.path == "/elsewhere")
    }

    @Test func providerThrottles429WithoutTreatingItAsZeroAllowance() async {
        let gate = AgentUsageThrottle()
        let first = await gate.rateLimited(.claude, retryAfter: "120", now: now)
        #expect(first.timeIntervalSince(now) == 900)
        #expect(await gate.retryDate(for: .claude, now: now.addingTimeInterval(100)) == first)
        #expect(await gate.retryDate(for: .codex, now: now) == nil)
        let second = await gate.rateLimited(.claude, retryAfter: nil, now: first)
        #expect(second.timeIntervalSince(first) == 1_800)
        await gate.succeeded(.claude)
        #expect(await gate.retryDate(for: .claude, now: now) == nil)
    }
}
