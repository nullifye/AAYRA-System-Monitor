import Foundation

/// Coding agents whose usage AAYRA can show. Agents with an `account` also have an account allowance;
/// the rest only have token counts read from their local files. An agent whose `reportsContextFill`
/// is true is the exception: it has no token ledger and instead reports how full its threads are.
///
/// Only agents with per-request, timestamped local records are listed, so "today" is a real count.
/// Tools that keep only running per-session totals (Goose, Factory Droid, Hermes), compressed or
/// server-side history (Zed, OpenClaw, Amp), or no token data (Crush) are deliberately left out.
enum AgentTool: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, copilot, openCode
    case gemini, qwen, cline, rooCode, kiloCode, kimi, pi, ohMyPi, cherryStudio, zcode
    /// Reports context-window fill from thread snapshots instead of a token ledger.
    case perch

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        case .openCode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .qwen: "Qwen Code"
        case .cline: "Cline"
        case .rooCode: "Roo Code"
        case .kiloCode: "Kilo Code"
        case .kimi: "Kimi"
        case .pi: "Pi"
        case .ohMyPi: "Oh My Pi"
        case .cherryStudio: "Cherry Studio"
        case .zcode: "ZCode"
        case .perch: "Perch AI"
        }
    }

    var account: AgentUsageStatus.Kind? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .copilot: .copilot
        case .openCode: .openCode
        default: nil
        }
    }

    /// Bundled icon in Resources/AgentIcons, if any.
    var assetName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .copilot: "copilot"
        case .openCode: "opencode"
        case .gemini: "gemini-cli"
        case .qwen: "qwen"
        case .cline: "cline"
        case .rooCode: nil
        case .kiloCode: "kilo"
        case .kimi: "kimi"
        case .pi: "pi"
        case .ohMyPi: "omp"
        case .cherryStudio: "cherrystudio"
        case .zcode: "zcode"
        case .perch: "perch"
        }
    }

    /// Whether the agent's local records say which folder it worked in.
    var recordsProjects: Bool { [.claude, .codex, .copilot, .openCode].contains(self) }

    /// Where the local token counts come from, shown as a tooltip.
    var dataHint: String {
        switch self {
        case .claude: "~/.claude/projects (JSONL)"
        case .codex: "~/.codex/sessions (JSONL)"
        case .copilot: "VS Code Copilot Chat sessions (workspaceStorage/*/chatSessions)"
        case .openCode: "~/.local/share/opencode/opencode.db (SQLite, read-only)"
        case .gemini: "~/.gemini/tmp/*/chats"
        case .qwen: "~/.qwen/projects/*/chats (JSONL)"
        case .cline: "Cline extension tasks (VS Code, Cursor, Windsurf) and ~/.cline/data/sessions"
        case .rooCode: "Roo Code extension tasks (VS Code, Cursor, Windsurf)"
        case .kiloCode: "Kilo Code extension tasks and ~/.local/share/kilo/kilo.db"
        case .kimi: "~/.kimi/sessions and ~/.kimi-code/sessions (wire.jsonl)"
        case .pi: "~/.pi/agent/sessions (JSONL)"
        case .ohMyPi: "~/.omp/agent/sessions (JSONL)"
        case .cherryStudio: "Cherry Studio agent transcripts (Application Support/CherryStudio)"
        case .zcode: "~/.zcode/cli/db/db.sqlite (SQLite, read-only)"
        case .perch: "~/.perch/threads (context snapshots, read-only)"
        }
    }

    /// Folders or files whose existence means the agent has been used on this Mac.
    func dataRoots(_ paths: AgentPaths) -> [URL] {
        func extensionStorage(_ id: String) -> [URL] {
            paths.editorUsers.map { $0.appendingPathComponent("globalStorage/\(id)", isDirectory: true) }
        }
        switch self {
        case .claude: return [paths.claude]
        case .codex: return [paths.codex.appendingPathComponent("sessions")]
        case .copilot: return paths.vscodeUsers.map { $0.appendingPathComponent("workspaceStorage") }
        case .openCode: return [paths.data.appendingPathComponent("opencode")]
        case .gemini: return [paths.dot(".gemini").appendingPathComponent("tmp")]
        case .qwen: return [paths.dot(".qwen").appendingPathComponent("projects")]
        case .cline: return extensionStorage("saoudrizwan.claude-dev") + [paths.clineSessions]
        case .rooCode: return extensionStorage("rooveterinaryinc.roo-cline")
        case .kiloCode: return extensionStorage("kilocode.kilo-code") + [paths.data.appendingPathComponent("kilo/kilo.db")]
        case .kimi:
            return [paths.dot(".kimi").appendingPathComponent("sessions"), paths.kimiCode.appendingPathComponent("sessions")]
        case .pi: return [paths.dot(".pi").appendingPathComponent("agent/sessions")]
        case .ohMyPi: return [paths.dot(".omp").appendingPathComponent("agent/sessions")]
        case .cherryStudio: return [paths.applicationSupport.appendingPathComponent("CherryStudio")]
        case .zcode: return [paths.dot(".zcode").appendingPathComponent("cli/db/db.sqlite")]
        case .perch: return [paths.perchThreads]
        }
    }

    /// Shown until the user ticks or unticks agents: the first three found on this Mac, in list order,
    /// plus any context-fill agent it finds (a cheap file read that was always shown before the
    /// chooser listed it as a row).
    static func defaultSelection(detected: Set<AgentTool>) -> Set<AgentTool> {
        var selection = Set(allCases.filter(detected.contains).prefix(3))
        selection.formUnion(allCases.filter { detected.contains($0) && $0.reportsContextFill })
        return selection
    }

    /// True for the card that reports context fill rather than a token ledger.
    var reportsContextFill: Bool { self == .perch }

    /// A saved order: unknown ids dropped, duplicates removed, new agents appended in list order.
    static func ordered(_ rawValues: [String]) -> [AgentTool] {
        var seen = Set<AgentTool>()
        var result = rawValues.compactMap { AgentTool(rawValue: $0) }.filter { seen.insert($0).inserted }
        result += allCases.filter { !seen.contains($0) }
        return result
    }

    /// `order` with `tool` moved directly before `target`. Returns the order unchanged when the two
    /// are the same or one of them is missing.
    static func moved(_ tool: AgentTool, before target: AgentTool, in order: [AgentTool]) -> [AgentTool] {
        guard tool != target,
            let from = order.firstIndex(of: tool),
            order.contains(target)
        else { return order }
        var result = order
        result.remove(at: from)
        let insertion = result.firstIndex(of: target) ?? result.endIndex
        result.insert(tool, at: insertion)
        return result
    }

    /// Cheap existence checks only: no file is opened or read.
    static func detectedOnThisMac(_ paths: AgentPaths = .init()) -> Set<AgentTool> {
        Set(allCases.filter { tool in tool.dataRoots(paths).contains { FileManager.default.fileExists(atPath: $0.path) } })
    }
}

/// Default data locations, honouring the same environment overrides the agents themselves use.
struct AgentPaths: Sendable {
    let home: URL
    let environment: [String: String]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.environment = environment
    }

    private func override(_ key: String) -> URL? {
        environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func dot(_ name: String) -> URL { home.appendingPathComponent(name, isDirectory: true) }

    var claude: URL { override("CLAUDE_CONFIG_DIR") ?? dot(".claude") }
    var codex: URL { override("CODEX_HOME") ?? dot(".codex") }
    var kimiCode: URL { override("KIMI_CODE_HOME") ?? dot(".kimi-code") }
    /// Cline's own precedence: each override wins outright.
    var clineSessions: URL {
        override("CLINE_SESSION_DATA_DIR")
            ?? override("CLINE_DATA_DIR")?.appendingPathComponent("sessions", isDirectory: true)
            ?? (override("CLINE_DIR") ?? dot(".cline")).appendingPathComponent("data/sessions", isDirectory: true)
    }
    /// `$XDG_DATA_HOME`, else `~/.local/share`.
    var data: URL { override("XDG_DATA_HOME") ?? home.appendingPathComponent(".local/share", isDirectory: true) }
    /// Where the Perch CLI writes one context snapshot per thread, honouring its own override.
    var perchThreads: URL {
        override("PERCH_CLI_STATE_DIR") ?? dot(".perch").appendingPathComponent("threads", isDirectory: true)
    }
    var applicationSupport: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }

    private func editorUser(_ app: String) -> URL {
        applicationSupport.appendingPathComponent(app, isDirectory: true).appendingPathComponent("User", isDirectory: true)
    }
    /// VS Code-family `User` folders where Copilot Chat stores sessions (stable, Insiders, VSCodium).
    var vscodeUsers: [URL] { ["Code", "Code - Insiders", "VSCodium"].map(editorUser) }
    /// Every editor that can host the Cline, Roo Code and Kilo Code extensions.
    var editorUsers: [URL] { vscodeUsers + ["Cursor", "Windsurf"].map(editorUser) }
}
