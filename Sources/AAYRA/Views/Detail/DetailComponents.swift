import SwiftUI

// Building blocks shared by every detail panel: the panel frame, grouped sections and rows.

/// Which card's detail panel is open.
enum DetailKind: Hashable { case cpu, gpu, storage, memory, battery, network }

/// A button in a detail panel's header, e.g. "Manage Storage…".
struct DetailAction {
    let title: String
    let symbol: String
    let perform: @MainActor () -> Void
}

/// Side panel shown next to the main panel when a card is clicked: a header, then grouped
/// sections in two equal columns (one column would outgrow a laptop screen).
struct DetailPanel<Leading: View, Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    var actions: [DetailAction] = []
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    #if DEBUG
        @Environment(\.isSnapshot) private var isSnapshot
    #else
        private let isSnapshot = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isSnapshot {
                columns  // offscreen screenshots can't draw scroll views
            } else {
                // The columns always sit in one scroll view, so expanding rows never rebuilds them (which
                // would collapse them again). It takes the content's natural height up to the room on
                // screen, and only scrolls, below a header that stays put, when the content is taller.
                ScrollView(.vertical) { columns }
                    .frame(maxHeight: maxColumnsHeight)
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(16)
        .frame(width: Metrics.detailWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 11) {
            IconBadge(symbol: symbol, color: tint, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if !isSnapshot {  // AppKit controls can't be drawn in offscreen screenshots
                HStack(spacing: 6) {
                    ForEach(actions.indices, id: \.self) { index in
                        let action = actions[index]
                        Button {
                            action.perform()
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) { leading() }
                .frame(maxWidth: .infinity)
            VStack(spacing: 14) { trailing() }
                .frame(maxWidth: .infinity)
        }
    }

    /// Room for the columns on the current screen, after the header, padding and popover frame.
    private var maxColumnsHeight: CGFloat {
        #if DEBUG
            let override = UserDefaults.standard.double(forKey: "debugDetailMaxHeight")  // for testing small screens
            if override > 0 { return override }
        #endif
        let screenHeight = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        // Leave room for the header, padding, the popover's frame and a small margin.
        return max(240, screenHeight - 170)
    }
}

/// Small uppercase title above a rounded group of rows separated by hairlines.
struct DetailSection<Content: View, Accessory: View>: View {
    let title: String
    let content: Content
    let accessory: Accessory

    init(_ title: String, @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.title = title
        self.content = content()
        self.accessory = EmptyView()
    }

    /// A section with a control at the right of its title, e.g. the chart range picker.
    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .padding(.leading, 2)
                Spacer(minLength: 0)
                accessory
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().opacity(0.5) }
                        row.padding(.vertical, 5)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(radius: 14)
        }
    }
}

/// Label on the left, value on the right. Values can be selected and copied.
struct DetailRow: View {
    let label: String
    let value: String
    var dot: Color?
    #if DEBUG
        /// Shown instead of `value` in screenshots, for personal identifiers (serials, addresses).
        var placeholder: String?
    #endif
    #if DEBUG
        @Environment(\.isSnapshot) private var isSnapshot
    #else
        private let isSnapshot = false  // screenshots are a debug-only feature
    #endif

    init(_ label: String, _ value: String, dot: Color? = nil, placeholder: String? = nil) {
        self.label = label
        self.value = value
        self.dot = dot
        #if DEBUG
            self.placeholder = placeholder
        #endif
    }

    private var shownValue: String {
        #if DEBUG
            if isSnapshot, let placeholder { return placeholder }
        #endif
        return value
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(shownValue)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .textSelection(.enabled)
            }
        }
        .font(.body)
    }
}

/// An app or process with its value and a thin bar showing its share. When several processes are
/// added together (an app and its helpers), clicking the row expands it to list them.
struct ProcessRow: View {
    struct Member: Identifiable {
        let id: pid_t
        let name: String
        let value: String
    }

    let name: String
    let value: String
    let fraction: Double
    let tint: Color
    /// How many processes are added together under this name (an app and its helpers).
    var count = 1
    var members: [Member] = []

    /// Expansion is owned by the list, so opening one app closes the others (one at a time).
    var isExpanded = false
    var onToggle: () -> Void = {}
    private static let visibleMembers = 8

    private var isExpandable: Bool { count > 1 && !members.isEmpty }

    var body: some View {
        if isExpandable {
            Button {
                withAnimation(.snappy(duration: 0.25)) { onToggle() }
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides its processes" : "Shows its \(count) processes")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if isExpandable {
                    // Disclosure triangle, as in macOS outline views: points right when
                    // collapsed and turns down when expanded.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                }
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if count > 1 {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                }
                Spacer(minLength: 8)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            UsageBar(fraction: max(fraction, 0.01), color: tint, height: 4)
            if isExpanded {
                memberList
                    .padding(.top, 3)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.body)
    }

    /// The processes inside the group, indented under the app, biggest first.
    private var memberList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(members.prefix(Self.visibleMembers)) { member in
                HStack(spacing: 8) {
                    Text(member.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(member.value)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            if members.count > Self.visibleMembers {
                Text("and \(members.count - Self.visibleMembers) more")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
    }
}

/// Placeholder row for lists that have no data yet.
struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text).font(.body).foregroundStyle(.tertiary)
    }
}

extension DetailAction {
    static let activityMonitor = DetailAction(title: "Activity Monitor", symbol: "waveform.path.ecg") {
        SystemActions.openActivityMonitor()
    }
}
