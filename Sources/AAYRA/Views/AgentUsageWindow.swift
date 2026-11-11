import AppKit
import Observation
import SwiftUI

enum AgentUsageLayout {
    /// Same width as the hardware panel, so both read as one family.
    static let width: CGFloat = Metrics.panelWidth + Metrics.floatMargin * 2

    static func height(for content: CGFloat, available: CGFloat) -> CGFloat {
        min(max(1, content), max(1, available))
    }

    static func needsScroll(content: CGFloat, available: CGFloat) -> Bool {
        content > available + 1
    }
}

@MainActor
@Observable
final class AgentUsageMonitor {
    private(set) var statuses: [AgentUsageStatus.Kind: AgentUsageStatus] = [:]
    private(set) var isRefreshing = false
    private(set) var localTokens: [AgentTool: AgentTokenUsage] = [:]
    private(set) var localTokensChecked = false
    /// Perch CLI thread context snapshots, newest first. Read from disk; costs no tokens.
    private(set) var perchThreads: [PerchThreadContext] = []
    private(set) var perchChecked = false
    /// When those snapshots were last re-read, which is not the same as when the CLI wrote them.
    private(set) var perchCheckedAt: Date?
    /// Tools whose data folder exists on this Mac; checked with cheap file-existence tests only.
    private(set) var detected: Set<AgentTool> = AgentTool.detectedOnThisMac()
    private(set) var choices = AppSettings.agentChoices
    /// User order for the chooser rows and panel cards; new agents are appended automatically.
    private(set) var order = AgentTool.ordered(AppSettings.agentOrder)

    /// Ticked in the panel's agent list, or by default: the first three agents found on this Mac.
    func isShown(_ tool: AgentTool) -> Bool {
        choices[tool.rawValue] ?? AgentTool.defaultSelection(detected: detected).contains(tool)
    }

    var shownTools: [AgentTool] { order.filter(isShown) }

    func setShown(_ tool: AgentTool, _ shown: Bool) {
        choices[tool.rawValue] = shown
        AppSettings.agentChoices = choices
    }

    /// Moves a dragged row directly before the row it was dropped on, and saves the new order.
    func move(_ tool: AgentTool, before target: AgentTool) {
        let updated = AgentTool.moved(tool, before: target, in: order)
        guard updated != order else { return }
        order = updated
        AppSettings.agentOrder = updated.map(\.rawValue)
    }

    func status(for kind: AgentUsageStatus.Kind) -> AgentUsageStatus {
        statuses[kind] ?? .unavailable(kind, isRefreshing ? "Checking…" : "Not checked yet")
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        localTokensChecked = false
        localTokens = [:]
        detected = AgentTool.detectedOnThisMac()
        // Unticked agents are skipped entirely: no files scanned, no sign-in read, no request sent.
        let shown = Set(shownTools)
        let kinds = shown.compactMap(\.account)
        let tokensTask = Task.detached(priority: .utility) { AgentLocalTokens.today(for: shown) }
        Task { [weak self] in
            let tokens = await tokensTask.value
            self?.localTokens = tokens
            self?.localTokensChecked = true
        }
        // Context-fill agents keep no token ledger: a file read each, no network.
        // Unticked agents are not read at all, so skip the scan when the agent is hidden.
        if shown.contains(where: \.reportsContextFill) {
            let perchTask = Task.detached(priority: .utility) { PerchContext.threads() }
            Task { [weak self] in
                let threads = await perchTask.value
                self?.perchThreads = threads
                self?.perchChecked = true
                self?.perchCheckedAt = Date()
            }
        } else {
            perchThreads = []
            perchChecked = false
            perchCheckedAt = nil
        }
        Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) { () async -> [AgentUsageStatus.Kind: AgentUsageStatus] in
                await withTaskGroup(of: AgentUsageStatus.self) { group in
                    for kind in kinds { group.addTask { await Self.account(kind) } }
                    var result: [AgentUsageStatus.Kind: AgentUsageStatus] = [:]
                    for await status in group { result[status.kind] = status }
                    return result
                }
            }.value
            self?.statuses = fresh
            self?.isRefreshing = false
        }
    }

    #if DEBUG
        /// Snapshot data for `--render`: sample allowances (no Keychain or network) and real local token counts.
        func loadSnapshot(now: Date = Date()) {
            detected = AgentTool.detectedOnThisMac()
            choices = [:]  // the default selection, whatever is saved
            localTokens = AgentLocalTokens.today(for: Set(shownTools), now: now)
            localTokensChecked = true
            let reset = now.addingTimeInterval(3 * 3_600)
            func sample(_ kind: AgentUsageStatus.Kind, _ left: Double) -> AgentUsageStatus {
                .init(
                    kind: kind,
                    allowances: [
                        .init(name: "5-hour", remaining: "", resetsAt: reset, remainingPercent: left),
                        .init(
                            name: "Weekly", remaining: "", resetsAt: reset.addingTimeInterval(3 * 86_400), remainingPercent: 64),
                    ], detail: "Sample allowance", checkedAt: now)
            }
            statuses = [.claude: sample(.claude, 72), .codex: sample(.codex, 41), .copilot: sample(.copilot, 88)]
            perchThreads = PerchContext.threads()
            perchChecked = true
            perchCheckedAt = Date()
        }
    #endif

    nonisolated private static func account(_ kind: AgentUsageStatus.Kind) async -> AgentUsageStatus {
        switch kind {
        case .claude: await AgentAccountUsage.claude()
        case .codex: await AgentAccountUsage.codex()
        case .copilot: await AgentAccountUsage.copilot()
        case .openCode:
            if let go = await AgentAccountUsage.openCodeGo() { go } else { AgentUsageProvider.openCode() }
        }
    }
}

/// An independent floating panel anchored to the Agent Usage icon, not the hardware panel.
@MainActor
final class AgentUsageWindow: NSObject {
    private let panel = FloatingPanel()
    private var timer: Timer?
    private var eventMonitors: [Any] = []
    private let monitor = AgentUsageMonitor()
    private weak var anchor: NSStatusBarButton?
    /// Last measured content height, so the panel reopens at its real size.
    private var lastContentHeight: CGFloat?

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(otherAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func toggle(from button: NSStatusBarButton) {
        if panel.isVisible { close() } else { show(from: button) }
    }

    func close() {
        guard panel.isVisible else { return }
        DetailPresenter.shared.closeAll()
        timer?.invalidate()
        timer = nil
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        anchor?.highlight(false)
        panel.orderOut(nil)
        panel.contentView = nil
        anchor = nil
    }

    private func show(from button: NSStatusBarButton) {
        anchor = button
        let screen = button.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 420, height: 500)
        let available = max(1, visible.height - 8)
        let host = NSHostingView(
            rootView: AgentUsageView(
                monitor: monitor, maxHeight: available, detailEdge: Self.detailEdge(for: button, in: visible)
            ) { [weak self] height in
                self?.resize(to: height, available: available)
            })
        // The window follows the measured content height via resize(to:), as the hardware panel does.
        host.sizingOptions = []
        let height = AgentUsageLayout.height(for: lastContentHeight ?? 500, available: available)
        let x = min(
            max((button.window?.frame.midX ?? visible.midX) - AgentUsageLayout.width / 2, visible.minX),
            visible.maxX - AgentUsageLayout.width)
        panel.setFrame(
            NSRect(x: x.rounded(), y: (visible.maxY - height).rounded(), width: AgentUsageLayout.width, height: height),
            display: true)
        panel.contentView = host
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        #if DEBUG
            DebugLayers.dumpLater(panel, name: "agent-panel")
        #endif
        monitor.refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.refresh() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.anchor?.window?.frame.contains(event.locationInWindow) != true else { return }
                    self.close()
                }
            })
        {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    if event.type == .keyDown, event.keyCode == 53 { self.close(); return true }
                    // The detail popover is a child window of the panel, so clicks in it keep the panel open.
                    let window = event.window
                    let isOurs =
                        window != nil
                        && (window == self.panel || window == self.anchor?.window
                            || (self.panel.childWindows ?? []).contains(window!))
                    if event.type != .keyDown, !isOurs { self.close() }
                    return false
                }
                return swallow ? nil : event
            })
        {
            eventMonitors.append(local)
        }
    }

    /// The side with room for a detail panel, as the hardware panel decides it.
    private static func detailEdge(for button: NSStatusBarButton, in visible: NSRect) -> Edge {
        let midX = button.window?.frame.midX ?? visible.midX
        let half = AgentUsageLayout.width / 2
        let leftRoom = midX - half - visible.minX
        let rightRoom = visible.maxX - (midX + half)
        return leftRoom >= Metrics.detailWidth || leftRoom >= rightRoom ? .leading : .trailing
    }

    /// Applies whenever SwiftUI reports a new content height, including the first report, which can
    /// arrive before the panel is on screen.
    private func resize(to contentHeight: CGFloat, available: CGFloat) {
        lastContentHeight = contentHeight
        guard anchor != nil, let screen = anchor?.window?.screen ?? NSScreen.main else { return }
        let height = AgentUsageLayout.height(for: contentHeight, available: available)
        guard abs(panel.frame.height - height) > 1 else { return }
        panel.setFrame(
            NSRect(
                x: panel.frame.minX, y: screen.visibleFrame.maxY - height,
                width: AgentUsageLayout.width, height: height),
            display: true)
    }

    @objc private func otherAppActivated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { close() }
    }
}

/// One card in the agent panel, after grouping the token-only agents.
private struct AgentPanelEntry: Identifiable {
    enum Kind {
        case provider(AgentTool)
        case local([AgentTool])
        /// An agent that reports context fill rather than a token ledger.
        case contextFill(AgentTool)
    }

    let id: String
    let kind: Kind
}

private struct AgentUsageView: View {
    let monitor: AgentUsageMonitor
    let maxHeight: CGFloat
    var detailEdge: Edge = .leading
    let onHeightChange: (CGFloat) -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var openDetail: DetailKind?
    @State var choosing = false
    /// Off only for offscreen `--render` snapshots, which can't draw scroll view contents.
    var scrolls = true
    @State private var shownBeforeChoosing: [AgentTool] = []

    var body: some View {
        if scrolls && AgentUsageLayout.needsScroll(content: contentHeight, available: maxHeight) {
            scrollingContent
        } else {
            // Laid out exactly like the hardware panel: no scroll view, so nothing is drawn behind the cards.
            // Pinned to the top so the header always stays visible while the window catches up with a new height.
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Only when the cards are taller than the display, so the last one is reached by scrolling.
    @ViewBuilder private var scrollingContent: some View {
        let scroll = ScrollView { content }
            .scrollIndicators(.automatic)
            .frame(width: AgentUsageLayout.width)
            .frame(maxHeight: .infinity, alignment: .top)
        if #available(macOS 26, *) {
            // The macOS 26 scroll edge effect draws a dark band along the edges of the transparent panel.
            scroll.scrollEdgeEffectHidden(true, for: .all)
        } else {
            scroll
        }
    }

    private var content: some View {
        cards
            .padding(Metrics.floatMargin)
            .frame(width: AgentUsageLayout.width)
            // Measured like the hardware panel (PanelView); the window then sizes itself to fit.
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                guard height > 1 else { return }
                contentHeight = height
                onHeightChange(height)
            }
    }

    /// Same container as the hardware panel, holding only glass cards: on macOS 26 they share one
    /// GlassEffectContainer and render with the same depth.
    private var cards: some View {
        FloatingStack {
            header

            if choosing {
                AgentChooser(monitor: monitor)
            } else {
                ForEach(entries) { entry in
                    switch entry.kind {
                    case .provider(let tool):
                        if let kind = tool.account {
                            // Click for usage by model and token type, like the hardware cards' detail panels.
                            AgentProviderCard(
                                tool: tool, status: monitor.status(for: kind), localTokens: monitor.localTokens[tool],
                                tokensChecked: monitor.localTokensChecked
                            )
                            .detailPopover(.agent(tool), selection: $openDetail, edge: detailEdge, tint: tool.tint) {
                                AgentDetail(tool: tool, monitor: monitor)
                            }
                        }
                    case .local(let tools):
                        AgentLocalCard(tools: tools, tokens: monitor.localTokens, checked: monitor.localTokensChecked)
                            .detailPopover(.otherAgents, selection: $openDetail, edge: detailEdge, tint: .gray) {
                                OtherAgentsDetail(tools: tools, monitor: monitor)
                            }
                    case .contextFill(let tool):
                        ContextFillCard(
                            tool: tool, threads: monitor.perchThreads, checked: monitor.perchChecked
                        )
                        .detailPopover(.contextFill(tool), selection: $openDetail, edge: detailEdge, tint: tool.tint) {
                            ContextFillDetail(tool: tool, monitor: monitor)
                        }
                    }
                }
                if monitor.shownTools.isEmpty {
                    Text("No agents selected. Use the gear button to choose agents.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .cardBackground(floating: true)
                }
            }
        }
    }

    /// Cards in the user's order: account agents individually, the token-only agents as one combined
    /// card where the first of them appears, and context-fill agents at their own positions.
    private var entries: [AgentPanelEntry] {
        var result: [AgentPanelEntry] = []
        var local: [AgentTool] = []
        var localIndex: Int?
        for tool in monitor.shownTools {
            if tool.reportsContextFill {
                result.append(.init(id: tool.rawValue, kind: .contextFill(tool)))
            } else if tool.account != nil {
                result.append(.init(id: tool.rawValue, kind: .provider(tool)))
            } else {
                if localIndex == nil {
                    localIndex = result.count
                    result.append(.init(id: "local", kind: .local([])))
                }
                local.append(tool)
            }
        }
        if let localIndex { result[localIndex] = .init(id: "local", kind: .local(local)) }
        return result
    }

    /// One line like the hardware panel's header: title, then the gear (choose agents) and Refresh.
    private var header: some View {
        HStack(spacing: 10) {
            Text(choosing ? "Show Agents" : "Agent Usage")
                .font(.body.weight(.semibold))
            Spacer(minLength: 6)
            if monitor.isRefreshing && !choosing {
                ProgressView().controlSize(.small)
            }
            Button(choosing ? "Done" : "Choose Agents", systemImage: choosing ? "checkmark.circle.fill" : "gearshape") {
                DetailPresenter.shared.closeAll()
                if choosing && monitor.shownTools != shownBeforeChoosing { monitor.refresh() }
                shownBeforeChoosing = monitor.shownTools
                choosing.toggle()
            }
            .imageScale(choosing ? .large : .medium)  // the Done tick, a little bigger
            .help(choosing ? "Done" : "Choose which agents to show")
            Button("Refresh", systemImage: "arrow.clockwise") { monitor.refresh() }
                .disabled(monitor.isRefreshing || choosing)
                .help("Refresh account limits and local tokens")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .cardBackground(floating: true)
    }
}

#if DEBUG
    /// `--render` entry point: the panel as shown, and with the agent list open.
    @MainActor
    enum AgentUsageSnapshot {
        static func views() -> [(String, AnyView)] {
            let monitor = AgentUsageMonitor()
            monitor.loadSnapshot()
            var views = [false, true].map { choosing in
                let view = AgentUsageView(
                    monitor: monitor, maxHeight: 2_000, onHeightChange: { _ in }, choosing: choosing, scrolls: false)
                return (choosing ? "agents-choose" : "agents", AnyView(view))
            }
            let detail = AgentDetail(tool: .claude, monitor: monitor)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .padding(28)
            views.append(("agents-detail", AnyView(detail)))
            let perch = ContextFillDetail(tool: .perch, monitor: monitor)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .padding(28)
            views.append(("agents-perch", AnyView(perch)))
            return views
        }
    }
#endif

/// Built on the same `Card` as CPU, Memory and Storage: icon on the left, title with the headline number
/// (the tightest allowance), then a bar and line per window. Click opens its detail panel.
private struct AgentProviderCard: View {
    let tool: AgentTool
    let status: AgentUsageStatus
    let localTokens: AgentTokenUsage?
    let tokensChecked: Bool

    /// The window that limits you first.
    private var tightest: AgentAllowance? {
        status.allowances.filter { $0.remainingPercent != nil }.min { $0.remainingPercent! < $1.remainingPercent! }
    }

    var body: some View {
        Card {
            AgentToolIcon(tool: tool)
        } header: {
            if let percent = tightest?.remainingPercent {
                MeterHeader(title: tool.name, value: "\(Int(percent.rounded()))%", suffix: "left")
            } else {
                Text(tool.name).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text("Unavailable").font(.callout).foregroundStyle(.secondary)
            }
        } details: {
            // Each window on its own rows, never combined: its bar, then its value and reset time.
            ForEach(status.allowances) { window in
                if let percent = window.remainingPercent {
                    StackedBar(
                        segments: [.init(value: percent / 100, color: AgentUsageStyle.color(percent, tint: tool.tint))],
                        height: 8)
                }
                HStack(spacing: 10) {
                    Stat(label: window.name, value: AgentUsageStyle.left(window) + " left")
                    Spacer(minLength: 0)
                    Text("Resets in \(AgentUsageStyle.untilReset(window.resetsAt))")
                }
            }
            HStack(spacing: 10) {
                Stat(label: "Today", value: AgentUsageStyle.tokens(localTokens, checked: tokensChecked))
                if !status.allowances.isEmpty, !status.detail.isEmpty {
                    Spacer(minLength: 0)
                    Text(status.detail).truncationMode(.tail)
                }
            }
            if status.allowances.isEmpty, !status.detail.isEmpty {
                Text(status.detail)
            }
        }
    }
}

/// Shared number formats and colours for the agent cards.
private enum AgentUsageStyle {
    /// The agent's colour, orange at 25 % left and red at 10 % left (75 % / 90 % used).
    static func color(_ percentLeft: Double, tint: Color) -> Color {
        percentLeft <= 10 ? .red : percentLeft <= 25 ? .orange : tint
    }

    static func left(_ allowance: AgentAllowance) -> String {
        if allowance.remaining.hasPrefix("$") {
            return String(allowance.remaining.prefix { $0 != " " })
        }
        return allowance.remainingPercent.map { "\(Int($0.rounded()))%" } ?? allowance.remaining
    }

    /// "24m", "5h", "3d": time until a window resets, short enough for two windows side by side.
    static func untilReset(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded(.up))))m" }
        if seconds < 86_400 { return "\(Int((seconds / 3_600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }

    /// The full count, e.g. "227,312,345".
    static func tokens(_ usage: AgentTokenUsage?, checked: Bool) -> String {
        guard let usage else { return checked ? "—" : "…" }
        return usage.total.formatted()
    }

    /// "62%" of a whole, or "<1%" for a sliver.
    static func share(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let percent = Double(part) / Double(whole) * 100
        return percent > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }
}

/// Every agent the panel can show, ticked or not, in the user's order. Drag a row onto another to
/// move it; the order is saved and also sets the panel's card order.
private struct AgentChooser: View {
    let monitor: AgentUsageMonitor

    var body: some View {
        list
        options
    }

    @AppStorage(AppSettings.Key.agentShowProjects) private var showProjects = false

    private var list: some View {
        // The title sits inside the card: only glass cards may live in the glass container.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Agents")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
                Text("Drag to reorder")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(monitor.order.enumerated()), id: \.element) { index, tool in
                    if index > 0 { Divider().padding(.leading, 72) }
                    row(tool)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(floating: true)
    }

    private func row(_ tool: AgentTool) -> some View {
        let found = monitor.detected.contains(tool)
        // The checkbox is its own control so it centres on the two-line row (a labelled checkbox
        // aligns to the first line); the whole row toggles it.
        let isOn = Binding(get: { monitor.isShown(tool) }, set: { monitor.setShown(tool, $0) })
        return HStack(alignment: .center, spacing: 10) {
            Toggle(tool.name, isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.large)
            AgentToolIcon(tool: tool, size: 24)
                .opacity(found ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).font(.body)
                Text(detail(tool, found: found))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .help(tool.dataHint)
        .onDrag { NSItemProvider(object: tool.rawValue as NSString) }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let source = AgentTool(rawValue: raw) else { return false }
            monitor.move(source, before: tool)
            return true
        }
    }

    private func detail(_ tool: AgentTool, found: Bool) -> String {
        let kind: String
        if tool.reportsContextFill {
            kind = "Context fill (local snapshots)"
        } else if tool.account != nil {
            kind = "Account limits + local tokens"
        } else {
            kind = "Local tokens"
        }
        return found ? kind : kind + " · Not found on this Mac"
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Options")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
            HStack(alignment: .center, spacing: 10) {
                Toggle("Show usage by project", isOn: $showProjects)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .controlSize(.large)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show usage by project").font(.body)
                    Text(
                        "Lists working-folder names in each agent's details. Off by default so they don't appear in screenshots."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { showProjects.toggle() }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(floating: true)
    }
}

/// Agents without an account allowance, as one `Card` whose headline is today's combined local tokens.
private struct AgentLocalCard: View {
    let tools: [AgentTool]
    let tokens: [AgentTool: AgentTokenUsage]
    let checked: Bool

    var body: some View {
        let total = tools.compactMap { tokens[$0]?.total }.reduce(0, +)
        Card(symbol: "square.stack.3d.up.fill", tint: .gray) {
            MeterHeader(
                title: "Other Agents", value: checked ? total.formatted() : "…",
                suffix: "today")
        } details: {
            ForEach(tools) { tool in
                HStack(spacing: 6) {
                    AgentToolIcon(tool: tool, size: 16)
                    Stat(label: tool.name, value: AgentUsageStyle.tokens(tokens[tool], checked: checked))
                    Spacer(minLength: 0)
                }
                .help(tool.dataHint)
            }
        }
    }
}

/// One agent's detail panel: today's local tokens by model and by type, and its account limits.
private struct AgentDetail: View {
    let tool: AgentTool
    let monitor: AgentUsageMonitor
    @AppStorage(AppSettings.Key.agentShowProjects) private var showProjects = false

    var body: some View {
        let usage = monitor.localTokens[tool]
        let status = tool.account.map { monitor.status(for: $0) }
        DetailPanel(
            symbol: tool.symbol, tint: tool.tint, title: tool.name, subtitle: subtitle(usage),
            actions: status?.kind.usageURL.map { url in
                [DetailAction(title: "Usage Page", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(url) }]
            } ?? [],
            icon: AnyView(AgentToolIcon(tool: tool, size: 36))
        ) {
            ModelBreakdown(title: "By Model", usage: usage, tint: tool.tint, checked: monitor.localTokensChecked)
            if showProjects { ProjectBreakdown(tool: tool, usage: usage, checked: monitor.localTokensChecked) }
        } trailing: {
            TokenTypeBreakdown(usage: usage, checked: monitor.localTokensChecked)
            if let status { AccountDetail(status: status) }
        }
    }

    private func subtitle(_ usage: AgentTokenUsage?) -> String {
        if let usage { return "Today · \(usage.total.formatted()) tokens on this Mac" }
        return monitor.localTokensChecked ? "No local usage recorded today" : "Scanning local usage…"
    }
}

/// A context-fill agent's card: its fullest thread's window, since such an agent reports no token
/// ledger and no readable quota. The headline is a share of the model's window, not money.
private struct ContextFillCard: View {
    let tool: AgentTool
    let threads: [PerchThreadContext]
    let checked: Bool

    /// The thread closest to its context limit.
    private var fullest: PerchThreadContext? {
        threads.max { $0.percent < $1.percent }
    }

    var body: some View {
        Card {
            AgentToolIcon(tool: tool)
        } header: {
            if let fullest {
                MeterHeader(title: tool.name, value: "\(Int(fullest.percent.rounded()))%", suffix: "context")
            } else {
                Text(tool.name).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(checked ? "No threads" : "Scanning…").font(.callout).foregroundStyle(.secondary)
            }
        } details: {
            if let fullest {
                StackedBar(
                    segments: [
                        .init(
                            value: fullest.percent / 100,
                            color: AgentUsageStyle.color(100 - fullest.percent, tint: tool.tint))
                    ],
                    height: 8)
                HStack(spacing: 10) {
                    Stat(label: "Used", value: "\(fullest.usedTokens.formatted()) of \(fullest.limitTokens.formatted())")
                    Spacer(minLength: 0)
                    Text(threads.count == 1 ? "1 thread" : "\(threads.count) threads")
                }
                HStack(spacing: 10) {
                    Stat(label: "Model", value: fullest.model ?? "—")
                    Spacer(minLength: 0)
                    Text(fullest.label).truncationMode(.tail)
                }
            } else {
                Text("\(tool.name) keeps no local token ledger. Open a thread in the CLI to see its context fill.")
            }
        }
    }
}

/// A context-fill agent's panel: every thread's fill, and what the fullest one is made of.
private struct ContextFillDetail: View {
    let tool: AgentTool
    let monitor: AgentUsageMonitor

    var body: some View {
        let threads = monitor.perchThreads
        let fullest = threads.max { $0.percent < $1.percent }
        DetailPanel(
            symbol: tool.symbol, tint: tool.tint, title: tool.name,
            subtitle: threads.isEmpty
                ? "No local threads"
                : "\(threads.count) thread\(threads.count == 1 ? "" : "s") · context fill, not spend",
            icon: AnyView(AgentToolIcon(tool: tool, size: 36))
        ) {
            DetailSection("Threads") {
                if threads.isEmpty {
                    Text(monitor.perchChecked ? "No \(tool.name) threads on this Mac" : "Scanning…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(threads.prefix(8)) { thread in
                        DetailRow(
                            thread.label,
                            "\(Int(thread.percent.rounded()))% · \(thread.usedTokens.formatted())")
                    }
                }
            }
            if let fullest, !fullest.sections.isEmpty {
                DetailSection("Context Breakdown") {
                    ForEach(fullest.sections.prefix(8)) { section in
                        DetailRow(
                            section.name,
                            "\(section.tokens.formatted()) · \(AgentUsageStyle.share(section.tokens, of: fullest.usedTokens))")
                    }
                }
            }
        } trailing: {
            if let fullest {
                DetailSection("Fullest Thread") {
                    DetailRow("Used", "\(fullest.usedTokens.formatted()) tokens")
                    DetailRow("Limit", "\(fullest.limitTokens.formatted()) tokens")
                    DetailRow("Fill", "\(Int(fullest.percent.rounded()))%")
                    if let model = fullest.model { DetailRow("Model", model) }
                    // The CLI's own write time, which is not when AAYRA last read the file.
                    DetailRow("Snapshot", fullest.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let checked = monitor.perchCheckedAt {
                        DetailRow("Checked", checked.formatted(date: .omitted, time: .shortened))
                    }
                }
                if let turn = fullest.lastTurn {
                    DetailSection("Last Turn") {
                        DetailRow("Input", turn.input.formatted())
                        DetailRow("Cache read", turn.cacheRead.formatted())
                        DetailRow("Output", turn.output.formatted())
                        DetailRow("Total", turn.total.formatted())
                    }
                }
            }
            DetailSection("About") {
                Text(
                    "Shows each thread's context-window fill, read from \(tool.dataHint). "
                        + "Snapshot is when the CLI wrote it; threads without one are skipped."
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The "Other Agents" card's panel: each agent's models, side by side.
private struct OtherAgentsDetail: View {
    let tools: [AgentTool]
    let monitor: AgentUsageMonitor

    var body: some View {
        let total = tools.compactMap { monitor.localTokens[$0]?.total }.reduce(0, +)
        DetailPanel(
            symbol: "square.stack.3d.up.fill", tint: .gray, title: "Other Agents",
            subtitle: "Today · \(total.formatted()) tokens on this Mac"
        ) {
            ForEach(Array(tools.enumerated()).filter { $0.offset.isMultiple(of: 2) }, id: \.element) { _, tool in
                section(tool)
            }
        } trailing: {
            ForEach(Array(tools.enumerated()).filter { !$0.offset.isMultiple(of: 2) }, id: \.element) { _, tool in
                section(tool)
            }
        }
    }

    private func section(_ tool: AgentTool) -> some View {
        ModelBreakdown(
            title: tool.name, usage: monitor.localTokens[tool], tint: tool.tint, checked: monitor.localTokensChecked)
    }
}

/// A split bar of the models' shares, then one row per model (largest first; the rest grouped).
private struct ModelBreakdown: View {
    let title: String
    let usage: AgentTokenUsage?
    let tint: Color
    let checked: Bool

    private static let colors: [Color] = [.blue, .purple, .pink, .green, .yellow]

    var body: some View {
        DetailSection(title) {
            if let usage, usage.total > 0 {
                let rows = Self.rows(usage, tint: tint)
                StackedBar(
                    segments: rows.map { .init(value: Double($0.tokens) / Double(usage.total), color: $0.color) }, height: 8)
                ForEach(rows, id: \.name) { row in
                    DetailRow(
                        row.name, "\(row.tokens.formatted()) · \(AgentUsageStyle.share(row.tokens, of: usage.total))",
                        dot: row.color)
                }
            } else {
                Text(checked ? "No usage recorded today" : "Scanning…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private static func rows(_ usage: AgentTokenUsage, tint: Color) -> [(name: String, tokens: Int64, color: Color)] {
        let sorted = usage.byModel.map { ($0.key, $0.value.total) }.sorted { $0.1 > $1.1 }
        let palette = [tint] + colors
        var rows = sorted.prefix(5).enumerated().map { index, model in (name: model.0, tokens: model.1, color: palette[index]) }
        let rest = sorted.dropFirst(5).reduce(Int64(0)) { $0 + $1.1 }
        if rest > 0 { rows.append((name: "Other models", tokens: rest, color: .gray)) }
        return rows
    }
}

/// Today's tokens per working folder: the folder's name, with its full path on hover.
private struct ProjectBreakdown: View {
    let tool: AgentTool
    let usage: AgentTokenUsage?
    let checked: Bool

    var body: some View {
        DetailSection("By Project") {
            if !tool.recordsProjects {
                Text("\(tool.name) doesn't record which folder it worked in.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let usage, usage.total > 0 {
                let rows = Self.rows(usage)
                ForEach(rows, id: \.path) { row in
                    DetailRow(row.name, "\(row.tokens.formatted()) · \(AgentUsageStyle.share(row.tokens, of: usage.total))")
                        .help(row.path)
                }
            } else {
                Text(checked ? "No usage recorded today" : "Scanning…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Largest first. Names are the folder's own name, or "parent/name" when two folders share one.
    private static func rows(_ usage: AgentTokenUsage) -> [(name: String, path: String, tokens: Int64)] {
        let sorted = usage.byProject.sorted { $0.value > $1.value }
        let shown = Array(sorted.prefix(6))
        let names = shown.map { URL(fileURLWithPath: $0.key).lastPathComponent }
        var rows = shown.enumerated().map { index, project -> (name: String, path: String, tokens: Int64) in
            let url = URL(fileURLWithPath: project.key)
            let clash = names.filter { $0 == names[index] }.count > 1
            let name = clash ? "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)" : names[index]
            return (name: name.isEmpty ? project.key : name, path: project.key, tokens: project.value)
        }
        let rest = sorted.dropFirst(6).reduce(Int64(0)) { $0 + $1.value }
        if rest > 0 { rows.append((name: "Other projects", path: "", tokens: rest)) }
        let unattributed = usage.total - usage.byProject.values.reduce(0, +)
        if unattributed > 0 { rows.append((name: "No folder recorded", path: "", tokens: unattributed)) }
        return rows
    }
}

/// What today's tokens were: fresh input, cache reads and writes, output and reasoning.
private struct TokenTypeBreakdown: View {
    let usage: AgentTokenUsage?
    let checked: Bool

    var body: some View {
        DetailSection("Token Types") {
            if let usage, usage.total > 0 {
                let tally = usage.tally
                let rows = [
                    ("Input", tally.input, Color.blue), ("Cache read", tally.cacheRead, Palette.memoryCached),
                    ("Cache write", tally.cacheWrite, Color.yellow), ("Output", tally.output, Color.orange),
                    ("Reasoning", tally.reasoning, Color.purple), ("Not broken down", tally.unclassified, Color.gray),
                ].filter { $0.1 > 0 }
                StackedBar(
                    segments: rows.map { .init(value: Double($0.1) / Double(tally.total), color: $0.2) }, height: 8)
                ForEach(rows, id: \.0) { name, tokens, color in
                    DetailRow(name, "\(tokens.formatted()) · \(AgentUsageStyle.share(tokens, of: tally.total))", dot: color)
                }
                if tally.cacheRead > tally.input + tally.output {
                    Text("Cache reads are earlier context re-read on each turn; they are counted but cost far less.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(checked ? "No usage recorded today" : "Scanning…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The account's limits with exact reset times, and how fresh they are.
private struct AccountDetail: View {
    let status: AgentUsageStatus

    var body: some View {
        DetailSection("Account") {
            ForEach(status.allowances) { window in
                DetailRow(window.name, "\(AgentUsageStyle.left(window)) left")
                DetailRow("Resets", window.resetsAt.formatted(date: .abbreviated, time: .shortened))
            }
            // Plan, credits and request counts: account details that aren't resetting allowances.
            ForEach(status.facts) { fact in
                DetailRow(fact.label, fact.value)
            }
            if !status.detail.isEmpty {
                Text(status.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let checked = status.checkedAt {
                DetailRow("Checked", checked.formatted(date: .omitted, time: .shortened))
            }
        }
    }
}

private struct AgentToolIcon: View {
    let tool: AgentTool
    var size: CGFloat = Metrics.badge

    var body: some View {
        Group {
            if let image = Self.images[tool] {
                // A circle like the hardware cards' IconBadge; every logo is a full-bleed tile, so nothing is lost.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .shadow(color: tool.tint.opacity(0.3), radius: 1, y: 0.5)
            } else {
                IconBadge(symbol: tool.symbol, color: tool.tint, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private static let images: [AgentTool: NSImage] = {
        var result: [AgentTool: NSImage] = [:]
        for tool in AgentTool.allCases {
            guard let name = tool.assetName, let url = Bundle.main.url(forResource: name, withExtension: "png"),
                let image = NSImage(contentsOf: url)
            else { continue }
            result[tool] = image
        }
        return result
    }()
}

extension AgentUsageStatus.Kind {
    fileprivate var usageURL: URL? {
        let address: String
        switch self {
        case .claude: address = "https://claude.ai/settings/usage"
        case .codex: address = "https://chatgpt.com/codex/settings/usage"
        case .copilot: address = "https://github.com/settings/billing"
        case .openCode: return nil
        }
        return URL(string: address)
    }
}

extension AgentTool {
    /// Fallback SF Symbol when no bundled icon exists.
    fileprivate var symbol: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .copilot: "chevron.left.slash.chevron.right"
        case .openCode: "bolt.horizontal.circle.fill"
        case .gemini: "sparkle"
        case .qwen: "cloud.fill"
        case .cline, .rooCode, .kiloCode: "puzzlepiece.extension.fill"
        case .kimi: "moon.fill"
        case .pi, .ohMyPi: "terminal.fill"
        case .cherryStudio: "leaf.fill"
        case .zcode: "z.circle.fill"
        case .perch: "bird.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .claude: .orange
        case .codex: .teal
        case .copilot: .purple
        case .openCode: .blue
        case .gemini: .blue
        case .qwen: .indigo
        case .cline: .gray
        case .rooCode: .green
        case .kiloCode: .yellow
        case .kimi: .cyan
        case .pi, .ohMyPi: .mint
        case .cherryStudio: .pink
        case .zcode: .indigo
        case .perch: Color(red: 47 / 255, green: 94 / 255, blue: 67 / 255)  // brand patina green
        }
    }
}
