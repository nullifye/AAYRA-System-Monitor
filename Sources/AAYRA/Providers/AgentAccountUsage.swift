import Foundation
import Security

private final class RejectUsageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A credential-bearing request must never be forwarded to a different URL.
        completionHandler(nil)
    }
}

/// Request pacing for the account usage endpoints, shared by every panel open, refresh and relaunch.
/// - At most one request per provider per `minimumInterval`; the last result is reused in between.
/// - A 429 is an endpoint throttle, not exhausted allowance: back off (doubling) and respect Retry-After.
/// - While throttled or failing, the last good allowance is shown, marked with when it was checked.
/// Only allowance percentages, reset times and pacing dates are persisted; never credentials.
actor AgentUsageThrottle {
    static let shared = AgentUsageThrottle(persistenceKey: "agentUsageAccountCache")

    enum Admission: Equatable {
        case request
        case reuse(AgentUsageStatus)
        case throttled(until: Date)
    }

    private struct Saved: Codable {
        var nextAttempt: [String: Date] = [:]
        var consecutiveFailures: [String: Int] = [:]
        var lastAttempt: [String: Date] = [:]
        var lastGood: [String: [AgentAllowance]] = [:]
        var lastGoodAt: [String: Date] = [:]
        var lastGoodFacts: [String: [AgentFact]]?
    }

    private let persistenceKey: String?
    private var nextAttempt: [AgentUsageStatus.Kind: Date] = [:]
    private var consecutiveFailures: [AgentUsageStatus.Kind: Int] = [:]
    private var lastAttempt: [AgentUsageStatus.Kind: Date] = [:]
    private var lastResult: [AgentUsageStatus.Kind: AgentUsageStatus] = [:]
    private var lastGood: [AgentUsageStatus.Kind: AgentUsageStatus] = [:]

    init(persistenceKey: String? = nil) {
        self.persistenceKey = persistenceKey
        guard let persistenceKey, let data = UserDefaults.standard.data(forKey: persistenceKey),
            let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        func keyed<Value>(_ values: [String: Value]) -> [AgentUsageStatus.Kind: Value] {
            Dictionary(
                uniqueKeysWithValues: values.compactMap { key, value in AgentUsageStatus.Kind(rawValue: key).map { ($0, value) } }
            )
        }
        nextAttempt = keyed(saved.nextAttempt)
        consecutiveFailures = keyed(saved.consecutiveFailures)
        lastAttempt = keyed(saved.lastAttempt)
        for (kind, allowances) in keyed(saved.lastGood) {
            let checked = saved.lastGoodAt[kind.rawValue]
            lastGood[kind] = .init(
                kind: kind, allowances: allowances, detail: "", checkedAt: checked,
                facts: saved.lastGoodFacts?[kind.rawValue] ?? [])
        }
    }

    /// Anthropic's endpoint throttles hardest, so Claude is asked least often.
    static func minimumInterval(for kind: AgentUsageStatus.Kind) -> TimeInterval {
        kind == .claude ? 300 : 120
    }

    func admit(_ kind: AgentUsageStatus.Kind, now: Date = Date()) -> Admission {
        if let date = retryDate(for: kind, now: now) { return .throttled(until: date) }
        if let last = lastAttempt[kind], now.timeIntervalSince(last) < Self.minimumInterval(for: kind),
            let result = lastResult[kind] ?? current(kind, now: now)
        {
            return .reuse(result)
        }
        lastAttempt[kind] = now
        save()
        return .request
    }

    /// The result to reuse until the next request is allowed.
    func record(_ status: AgentUsageStatus) {
        lastResult[status.kind] = status
        if !status.allowances.isEmpty, status.detail.isEmpty {
            lastGood[status.kind] = status
            save()
        }
    }

    /// The last good allowance as it was checked (e.g. after a relaunch), minus windows that have since reset.
    private func current(_ kind: AgentUsageStatus.Kind, now: Date) -> AgentUsageStatus? {
        guard let good = lastGood[kind] else { return nil }
        let windows = good.allowances.filter { $0.resetsAt > now }
        return windows.isEmpty
            ? nil : .init(kind: kind, allowances: windows, detail: "", checkedAt: good.checkedAt, facts: good.facts)
    }

    /// The last good allowance with windows that have since reset removed, explained by `reason`.
    func stale(_ kind: AgentUsageStatus.Kind, now: Date = Date(), reason: String) -> AgentUsageStatus? {
        guard let good = lastGood[kind] else { return nil }
        let current = good.allowances.filter { $0.resetsAt > now }
        guard !current.isEmpty else { return nil }
        let checked = good.checkedAt.map { " · showing values from \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return .init(kind: kind, allowances: current, detail: reason + checked, checkedAt: good.checkedAt, facts: good.facts)
    }

    func retryDate(for kind: AgentUsageStatus.Kind, now: Date = Date()) -> Date? {
        guard let date = nextAttempt[kind], date > now else { return nil }
        return date
    }

    func rateLimited(_ kind: AgentUsageStatus.Kind, retryAfter: String?, now: Date = Date()) -> Date {
        let count = min(6, (consecutiveFailures[kind] ?? 0) + 1)
        consecutiveFailures[kind] = count
        let backoff = min(6 * 3_600.0, 900 * pow(2, Double(count - 1)))
        let seconds = max(backoff, Self.retryAfterSeconds(retryAfter, now: now) ?? 0)
        let date = now.addingTimeInterval(min(86_400, seconds))
        nextAttempt[kind] = date
        save()
        return date
    }

    func succeeded(_ kind: AgentUsageStatus.Kind) {
        nextAttempt[kind] = nil
        consecutiveFailures[kind] = nil
        save()
    }

    private func save() {
        guard let persistenceKey else { return }
        func keyed<Value>(_ values: [AgentUsageStatus.Kind: Value]) -> [String: Value] {
            Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        }
        let saved = Saved(
            nextAttempt: keyed(nextAttempt), consecutiveFailures: keyed(consecutiveFailures),
            lastAttempt: keyed(lastAttempt), lastGood: keyed(lastGood.mapValues(\.allowances)),
            lastGoodAt: keyed(lastGood.compactMapValues(\.checkedAt)), lastGoodFacts: keyed(lastGood.mapValues(\.facts)))
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: persistenceKey) }
    }

    static func retryAfterSeconds(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Read-only use of existing provider sign-ins when the optional Agent Usage panel is open.
/// Never read or redeem refresh tokens, write credentials, or include secrets in errors.
enum AgentAccountUsage {
    private struct Credential {
        let accessToken: String
        let accountID: String?
    }

    /// Uses Gemini CLI's existing Google OAuth access token. Never refreshes or writes credentials.
    static func gemini(now: Date = Date(), paths: AgentPaths = .init()) async -> AgentUsageStatus {
        let file = paths.dot(".gemini").appendingPathComponent("oauth_creds.json")
        guard let data = try? Data(contentsOf: file), data.count <= 64_000,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = root["access_token"] as? String, !token.isEmpty,
            let expiry = AgentLocalTokens.date(root["expiry_date"]), expiry > now.addingTimeInterval(30)
        else { return .unavailable(.gemini, "No current Gemini CLI Google sign-in; sign in again with Gemini CLI") }
        let gate = AgentUsageThrottle.shared
        switch await gate.admit(.gemini, now: now) {
        case .reuse(let status): return status
        case .throttled(let retry): return await failed(.gemini, rateLimitedUntil: retry, now: now)
        case .request: break
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RejectUsageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ method: String, body: [String: Any]) throws -> URLRequest {
            var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
        do {
            var project = paths.environment["GOOGLE_CLOUD_PROJECT"] ?? paths.environment["GOOGLE_CLOUD_PROJECT_ID"]
            if project == nil {
                let (data, response) = try await session.data(
                    for: request("loadCodeAssist", body: ["metadata": ["ideType": "GEMINI_CLI"]]))
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if response.statusCode == 429 {
                    let retry = await gate.rateLimited(
                        .gemini, retryAfter: response.value(forHTTPHeaderField: "Retry-After"), now: now)
                    return await failed(.gemini, rateLimitedUntil: retry, now: now)
                }
                if let reason = httpFailure(response.statusCode) {
                    let status = await failed(.gemini, reason: reason, now: now)
                    await gate.record(status)
                    return status
                }
                guard data.count <= 256_000,
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw URLError(.cannotParseResponse) }
                project =
                    object["cloudaicompanionProject"] as? String
                    ?? (object["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
            }
            guard let project, !project.isEmpty else {
                let status = AgentUsageStatus.unavailable(.gemini, "Gemini sign-in did not provide a Code Assist project")
                await gate.record(status)
                return status
            }
            // fetch() applies response limits, provider pacing, 429 backoff and stale-result handling.
            let status = await send(
                try request("retrieveUserQuota", body: ["project": project]), kind: .gemini, now: now,
                parse: parseGeminiQuota, facts: { _, _ in [] })
            await gate.record(status)
            return status
        } catch {
            let status = await failed(.gemini, reason: "Could not read Gemini account quota", now: now)
            await gate.record(status)
            return status
        }
    }

    static func parseGeminiQuota(_ data: Data, now: Date) -> [AgentAllowance] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let buckets = root["buckets"] as? [[String: Any]]
        else { return [] }
        var windows: [String: AgentAllowance] = [:]
        for bucket in buckets {
            guard let model = bucket["modelId"] as? String, !model.isEmpty,
                let fraction = bucket["remainingFraction"] as? NSNumber,
                CFGetTypeID(fraction) != CFBooleanGetTypeID(), fraction.doubleValue.isFinite,
                (0...1).contains(fraction.doubleValue),
                let reset = AgentLocalTokens.date(bucket["resetTime"]), reset > now,
                reset < now.addingTimeInterval(35 * 86_400)
            else { continue }
            let kind = bucket["tokenType"] as? String ?? "Quota"
            let name = "\(model) · \(kind)"
            let value = fraction.doubleValue * 100
            if value < (windows[name]?.remainingPercent ?? 101) {
                windows[name] = .init(
                    name: name, remaining: "\(Int(value.rounded()))% remaining", resetsAt: reset, remainingPercent: value)
            }
        }
        return windows.values.sorted { $0.name < $1.name }
    }

    static func claude(now: Date = Date()) async -> AgentUsageStatus {
        let credential: Credential?
        do {
            credential = try claudeCredential(now: now)
        } catch {
            return .unavailable(.claude, "Could not read Claude Code sign-in; check Keychain access")
        }
        guard let credential else {
            return .unavailable(.claude, "No usable Claude Code sign-in; sign in with Claude Code")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-cli/2.1.280 (external, cli)", forHTTPHeaderField: "User-Agent")
        return await fetch(request, kind: .claude, now: now, parse: parseClaude, facts: parseClaudeFacts)
    }

    static func codex(now: Date = Date()) async -> AgentUsageStatus {
        guard let credential = codexCredential() else {
            let local = AgentUsageProvider.codex(now: now)
            return local.allowances.isEmpty
                ? .unavailable(.codex, "No Codex sign-in or recent local rate-limit snapshot") : local
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credential.accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID") }
        let live = await fetch(request, kind: .codex, now: now, parse: parseCodexUsage, facts: parseCodexFacts)
        guard live.allowances.isEmpty || !live.detail.isEmpty else { return live }
        // Throttled, failing or stale: a recent rate-limit snapshot from local Codex sessions is newer information.
        let local = AgentUsageProvider.codex(now: now)
        guard !local.allowances.isEmpty, (local.checkedAt ?? .distantPast) > (live.checkedAt ?? .distantPast) else { return live }
        return local
    }

    /// Token Monitor's OpenCode Go source: a Go-specific API key in OpenCode's own auth.json.
    /// A Zen key is not a Go subscription key and must never be tried at this endpoint.
    static func openCodeGo(now: Date = Date()) async -> AgentUsageStatus? {
        let root =
            ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        let path = root.appendingPathComponent("opencode/auth.json")
        guard let data = try? Data(contentsOf: path), let key = parseOpenCodeGoKey(data) else { return nil }
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await fetch(request, kind: .openCode, now: now, parse: parseOpenCodeGo)
    }

    static func parseOpenCodeGoKey(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entry = root["opencode-go"] as? [String: Any],
            entry["type"] as? String == "api",
            let key = entry["key"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return key
    }

    static func copilot(now: Date = Date()) async -> AgentUsageStatus {
        guard let token = existingGitHubToken() else {
            return .unavailable(.copilot, "No existing GitHub credential available for Copilot limits")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        return await fetch(request, kind: .copilot, now: now, parse: parseCopilot, facts: parseCopilotFacts)
    }

    private static func existingGitHubToken() -> String? {
        for name in ["COPILOT_API_TOKEN", "GITHUB_COPILOT_TOKEN"] {
            if let token = ProcessInfo.processInfo.environment[name], !token.isEmpty { return token }
        }
        guard
            let path = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count < 2_048,
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else { return nil }
        return token
    }

    private static func claudeCredential(now: Date) throws -> Credential? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        // Claude Code on macOS generally owns a login-Keychain item; older installs use a file.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let data: Data
        if status == errSecSuccess, let secret = item as? Data {
            data = secret
        } else if status == errSecItemNotFound {
            guard let fileData = try? Data(contentsOf: file) else { return nil }
            data = fileData
        } else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = ((root["claudeAiOauth"] as? [String: Any]) ?? (root["oauth"] as? [String: Any]) ?? root)["accessToken"]
                as? String,
            !token.isEmpty
        else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? (root["oauth"] as? [String: Any]) ?? root
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            let seconds = expires > 20_000_000_000 ? expires / 1000 : expires
            if seconds <= now.timeIntervalSince1970 + 30 { return nil }
        }
        return Credential(accessToken: token, accountID: nil)
    }

    private static func codexCredential() -> Credential? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            !["api_key", "apikey"].contains((root["auth_mode"] as? String ?? "").lowercased()),
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return Credential(accessToken: token, accountID: tokens["account_id"] as? String)
    }

    private static func fetch(
        _ request: URLRequest, kind: AgentUsageStatus.Kind, now: Date,
        parse: (Data, Date) -> [AgentAllowance], facts: (Data, Date) -> [AgentFact] = { _, _ in [] }
    ) async -> AgentUsageStatus {
        let gate = AgentUsageThrottle.shared
        switch await gate.admit(kind, now: now) {
        case .reuse(let status): return status
        case .throttled(let retry): return await failed(kind, rateLimitedUntil: retry, now: now)
        case .request: break
        }
        let status = await send(request, kind: kind, now: now, parse: parse, facts: facts)
        await gate.record(status)
        return status
    }

    /// The last good numbers if they are still current, otherwise just the reason.
    private static func failed(_ kind: AgentUsageStatus.Kind, reason: String, now: Date) async -> AgentUsageStatus {
        await AgentUsageThrottle.shared.stale(kind, now: now, reason: reason) ?? .unavailable(kind, reason)
    }

    private static func failed(_ kind: AgentUsageStatus.Kind, rateLimitedUntil retry: Date, now: Date) async -> AgentUsageStatus {
        await failed(
            kind, reason: "Usage service busy · retry after \(retry.formatted(date: .omitted, time: .shortened))", now: now)
    }

    private static func send(
        _ request: URLRequest, kind: AgentUsageStatus.Kind, now: Date,
        parse: (Data, Date) -> [AgentAllowance], facts: (Data, Date) -> [AgentFact]
    ) async -> AgentUsageStatus {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RejectUsageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return await failed(kind, reason: "Usage server did not respond", now: now)
            }
            if kind == .openCode, response.statusCode == 403,
                data.count <= 256_000,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = object["error"] as? [String: Any], error["type"] as? String == "EntitlementError"
            {
                return .unavailable(.openCode, "No OpenCode Go subscription for this account")
            }
            if kind == .copilot, response.statusCode == 401 || response.statusCode == 403 {
                return .unavailable(.copilot, "Existing GitHub credential cannot access Copilot quota")
            }
            if response.statusCode == 429 {
                let retry = await AgentUsageThrottle.shared.rateLimited(
                    kind, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
                return await failed(kind, rateLimitedUntil: retry, now: now)
            }
            if let reason = httpFailure(response.statusCode) { return await failed(kind, reason: reason, now: now) }
            guard data.count <= 256_000 else { return .unavailable(kind, "Usage response is too large") }
            let allowances = parse(data, now)
            await AgentUsageThrottle.shared.succeeded(kind)
            return allowances.isEmpty
                ? .unavailable(kind, "Usage service returned no current allowance windows")
                : .init(kind: kind, allowances: allowances, detail: "", checkedAt: Date(), facts: facts(data, now))
        } catch {
            // Do not interpolate system errors: some may include request headers or URLs.
            return await failed(kind, reason: "Could not reach the usage service", now: now)
        }
    }

    static func httpFailure(_ status: Int) -> String? {
        switch status {
        case 200..<300: nil
        case 401, 403: "Sign-in expired or access denied; sign in again using the provider app"
        case 429: "Usage service rate-limited; try again later"
        default: "Usage service returned HTTP \(status)"
        }
    }

    static func parseClaude(_ data: Data, now: Date) -> [AgentAllowance] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var windows: [AgentAllowance] = [
            ("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Opus weekly"),
            ("seven_day_sonnet", "Sonnet weekly"),
        ].compactMap { key, name in
            guard let window = root[key] as? [String: Any],
                let used = (window["utilization"] as? NSNumber)?.doubleValue,
                let reset = window["resets_at"] as? String
            else { return nil }
            return allowance(name: name, used: used, reset: isoDate(reset), now: now)
        }
        // Per-model weekly caps also arrive as `weekly_scoped` entries in `limits[]`.
        for entry in root["limits"] as? [[String: Any]] ?? [] where entry["kind"] as? String == "weekly_scoped" {
            guard let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                !model.isEmpty, model.count < 40,
                let used = number(entry["utilization"] ?? entry["percent"]),
                let reset = entry["resets_at"] as? String
            else { continue }
            let name = "\(model) weekly"
            guard !windows.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                let window = allowance(name: name, used: used, reset: isoDate(reset), now: now)
            else { continue }
            windows.append(window)
        }
        return windows
    }

    /// Extra usage credits (money spent beyond the plan this month), when the account has them turned on.
    static func parseClaudeFacts(_ data: Data, now: Date) -> [AgentFact] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let spend = root["spend"] as? [String: Any]
        let extra = root["extra_usage"] as? [String: Any]
        guard spend?["enabled"] as? Bool == true || extra?["is_enabled"] as? Bool == true else { return [] }
        // `spend` amounts describe their own units; `extra_usage` shares one `decimal_places`.
        func spendMoney(_ value: Any?) -> (amount: Double, currency: String?)? {
            guard let money = value as? [String: Any], let minor = number(money["amount_minor"]) else { return nil }
            let exponent = number(money["exponent"]) ?? 2
            return (minor / pow(10, exponent), money["currency"] as? String)
        }
        func extraMoney(_ key: String) -> Double? {
            guard let raw = number(extra?[key]) else { return nil }
            let places = number(extra?["decimal_places"]).flatMap { $0 >= 0 ? $0 : nil } ?? 2
            return raw / pow(10, places)
        }
        let spentUsed = spendMoney(spend?["used"])
        guard let used = spentUsed?.amount ?? extraMoney("used_credits"), used.isFinite, used >= 0 else { return [] }
        let limit = spendMoney(spend?["limit"])?.amount ?? extraMoney("monthly_limit")
        let currency = (spentUsed?.currency ?? extra?["currency"] as? String ?? "USD").uppercased()
        let format = FloatingPointFormatStyle<Double>.Currency(code: currency)
        let value =
            limit.map { "\(used.formatted(format)) of \($0.formatted(format)) used" } ?? "\(used.formatted(format)) used"
        return [AgentFact(label: "Usage credits", value: value)]
    }

    /// The plan, and extra metered features (e.g. code review) that have their own limits.
    static func parseCodexFacts(_ data: Data, now: Date) -> [AgentFact] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var facts: [AgentFact] = []
        if let plan = root["plan_type"] as? String, !plan.isEmpty { facts.append(.init(label: "Plan", value: planName(plan))) }
        for entry in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let feature = (entry["limit_name"] as? String) ?? (entry["metered_feature"] as? String) ?? ""
            guard !feature.isEmpty, feature.count < 60, let limits = entry["rate_limit"] as? [String: Any] else { continue }
            for key in ["primary_window", "secondary_window"] {
                guard let window = limits[key] as? [String: Any],
                    let used = number(window["used_percent"]),
                    let limit = allowance(
                        name: feature, used: used, reset: AgentLocalTokens.date(window["reset_at"]), now: now)
                else { continue }
                let length = number(window["limit_window_seconds"]).map { windowName(seconds: $0) }
                facts.append(
                    .init(
                        label: [planName(feature), length].compactMap { $0 }.joined(separator: " · "),
                        value: "\(Int((limit.remainingPercent ?? 0).rounded()))% left · resets \(limit.resetDescription)"))
            }
        }
        return facts
    }

    /// The plan, premium requests as a count ("212 of 300 left"), and which features are unlimited.
    static func parseCopilotFacts(_ data: Data, now: Date) -> [AgentFact] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var facts: [AgentFact] = []
        if let plan = root["copilot_plan"] as? String, !plan.isEmpty { facts.append(.init(label: "Plan", value: planName(plan))) }
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        for (key, label) in [("premium_interactions", "Premium requests"), ("chat", "Chat"), ("completions", "Code completions")]
        {
            guard let snapshot = snapshots[key] as? [String: Any] else { continue }
            if snapshot["unlimited"] as? Bool == true {
                facts.append(.init(label: label, value: "Unlimited"))
            } else if let remaining = number(snapshot["remaining"]), let entitlement = number(snapshot["entitlement"]),
                entitlement > 0, remaining >= 0
            {
                facts.append(.init(label: label, value: "\(Int(remaining).formatted()) of \(Int(entitlement).formatted()) left"))
            }
        }
        return facts
    }

    /// "plus" → "Plus", "copilot_pro" → "Copilot Pro".
    private static func planName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func windowName(seconds: Double) -> String {
        switch seconds {
        case 18_000: "5-hour"
        case 604_800: "weekly"
        case 86_400: "daily"
        default: seconds >= 86_400 ? "\(Int(seconds / 86_400))-day" : "\(Int(seconds / 3_600))-hour"
        }
    }

    static func parseCodexUsage(_ data: Data, now: Date) -> [AgentAllowance] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limits = root["rate_limit"] as? [String: Any]
        else { return [] }
        return [("primary_window", "5-hour"), ("secondary_window", "Weekly")].compactMap { key, name in
            guard let window = limits[key] as? [String: Any],
                let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { return nil }
            return allowance(name: name, used: used, reset: AgentLocalTokens.date(window["reset_at"]), now: now)
        }
    }

    static func parseOpenCodeGo(_ data: Data, now: Date) -> [AgentAllowance] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usage = root["usage"] as? [String: Any]
        else { return [] }
        let windows: [AgentAllowance] = [("rolling", "Rolling"), ("weekly", "Weekly"), ("monthly", "Monthly")]
            .compactMap { key, name in
                guard let entry = usage[key] as? [String: Any],
                    let used = (entry["percent"] as? NSNumber)?.doubleValue,
                    let reset = entry["resetsAt"] as? String
                else { return nil }
                return allowance(name: name, used: used, reset: isoDate(reset), now: now)
            }
        // OpenCode Go always has both rolling and weekly windows. Missing one signals a changed response.
        return windows.contains(where: { $0.name == "Rolling" }) && windows.contains(where: { $0.name == "Weekly" })
            ? windows : []
    }

    static func parseCopilot(_ data: Data, now: Date) -> [AgentAllowance] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let resetText = root["quota_reset_date"] as? String
        else { return [] }
        // The quota date is usually a calendar day, occasionally a full timestamp.
        let instant = isoDate(resetText)
        guard let reset = instant ?? dateOnly(resetText), reset > now, reset < now.addingTimeInterval(35 * 86_400)
        else { return [] }
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        let monthly = root["monthly_quotas"] as? [String: Any] ?? [:]
        let limited = root["limited_user_quotas"] as? [String: Any] ?? [:]
        return [("premium_interactions", "Premium"), ("chat", "Chat")].compactMap { key, name in
            let snapshot = snapshots[key] as? [String: Any] ?? [:]
            guard snapshot["unlimited"] as? Bool != true else { return nil }
            let countKey = key == "premium_interactions" ? "completions" : "chat"
            let percent = number(snapshot["percent_remaining"])
            let remaining = number(snapshot["remaining"]) ?? number(limited[countKey])
            let entitlement = number(snapshot["entitlement"]) ?? number(monthly[countKey])
            let verified: Double?
            if let percent {
                verified = percent
            } else if let remaining, let entitlement, entitlement > 0 {
                verified = remaining / entitlement * 100
            } else {
                verified = nil
            }
            guard let verified, verified.isFinite, (0...100).contains(verified) else { return nil }
            return AgentAllowance(
                name: name, remaining: "\(Int(verified.rounded()))% remaining", resetsAt: reset,
                resetsAtIsDateOnly: instant == nil, remainingPercent: verified)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// "2027-01-20" names a calendar day, not an instant. Build that day at *local* midnight: parsing it as
    /// UTC midnight would show the previous day anywhere west of Greenwich (and a made-up time everywhere).
    private static func dateOnly(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    private static func allowance(name: String, used: Double, reset: Date?, now: Date) -> AgentAllowance? {
        guard used.isFinite, (0...100).contains(used), let reset,
            reset > now, reset < now.addingTimeInterval(35 * 86_400)
        else { return nil }
        return .init(
            name: name, remaining: "\(Int((100 - used).rounded()))% remaining", resetsAt: reset,
            remainingPercent: 100 - used)
    }
}
