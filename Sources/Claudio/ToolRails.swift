#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// Design 8c, two rails (like PyCharm): the left rail's tools cover projects
// (Sessions, Pull Requests, and the Shell at its foot), the right rail's
// cover the selected session (Changes, Pull Request). The side a tool is on
// says what it covers. App-wide figures live in the status bar.

enum ToolRail {
    static let width: CGFloat = 44
    /// The rails' icons start below the window's traffic lights, level with
    /// the headers' bottom edge.
    static let topInset: CGFloat = 52
    /// Room a header right of the left rail leaves for the traffic lights,
    /// which are wider than the rail.
    static let trafficLightInset: CGFloat = 34
    static let rightPanelWidth: CGFloat = 320

    /// With the left rail's tool hidden, the session and overview headers
    /// start beside the rail, under the traffic lights, so they leave room.
    @MainActor static func headerInset(_ model: AppModel) -> CGFloat {
        model.toolWindows.visibleLeft == nil ? trafficLightInset : 0
    }
}

/// A tool's title bar: "SESSIONS", with the tool's own buttons at the end.
struct ToolHeader<Accessory: View>: View {
    let title: String
    var leadingInset: CGFloat = 0
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: leadingInset)
            Text(title.uppercased())
                .font(DS.font(11, .extraBold))
                .kerning(0.66)
                .foregroundStyle(DS.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: ToolRail.topInset)
    }
}

/// One rail button: an icon, highlighted while its tool shows, with an
/// optional count.
private struct RailButton: View {
    let systemName: String
    let help: String
    let isActive: Bool
    var badge: Int = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundStyle(isActive || hovering ? DS.text : DS.muted)
                .frame(width: ToolRail.width, height: ToolRail.width)
                .background(isActive ? DS.selection : .clear)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(DS.font(9.5, .extraBold))
                            .monospacedDigit()
                            .foregroundStyle(DS.text)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(DS.blue))
                            .padding(.top, 5)
                            .padding(.trailing, 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Left rail (projects)

struct LeftRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let showing = model.toolWindows.visibleLeft
        VStack(spacing: 0) {
            Spacer().frame(height: ToolRail.topInset)
            RailButton(systemName: "list.bullet.indent", help: help("Sessions", showing == .sessions, "⌘1"),
                       isActive: showing == .sessions) { model.toggleTool(.sessions) }
            RailButton(systemName: "arrow.triangle.pull", help: help("Pull Requests", showing == .pullRequests, "⌘2"),
                       isActive: showing == .pullRequests) { model.toggleTool(.pullRequests) }
            Spacer(minLength: 0)
            // The Shell's tool window runs under the panes, as in PyCharm.
            let open = model.shellPanel.isOpen
            RailButton(systemName: "terminal", help: help("Shell", open, "⌃`"),
                       isActive: open, badge: open ? 0 : model.shellPanel.tabs.count) { model.toggleShellPanel() }
                .padding(.bottom, 4)
        }
        .frame(width: ToolRail.width)
        .frame(maxHeight: .infinity)
        .background(DS.sidebar)
    }

    private func help(_ tool: String, _ showing: Bool, _ shortcut: String) -> String {
        "\(showing ? "Hide" : "Show") \(tool) (\(shortcut))"
    }
}

/// The left rail's open tool.
struct LeftToolPanel: View {
    @Environment(AppModel.self) private var model
    let tool: LeftTool
    let width: Double

    var body: some View {
        Group {
            switch tool {
            case .sessions:
                SidebarView(width: width)
            case .pullRequests:
                VStack(spacing: 0) {
                    ToolHeader(title: "Pull Requests", leadingInset: ToolRail.trafficLightInset) {
                        IconButton(systemName: "arrow.clockwise", help: "Refresh Pull Requests", size: 13) {
                            Task { await model.refreshAllPullRequests(force: true) }
                        }
                    }
                    ProjectPullRequestsTool()
                }
                .frame(width: width)
            }
        }
        .frame(maxHeight: .infinity)
        .background(DS.sidebar)
    }
}

// MARK: - Right rail (the selected session)

struct RightRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let showing = model.toolWindows.visibleRight
        let session = model.selectedSession
        let files = session.flatMap { model.currentChanges(for: $0.id)?.files.count } ?? 0
        let pullRequests = session.map { model.pullRequestLinks(ofSession: $0.id).count } ?? 0
        VStack(spacing: 0) {
            Spacer().frame(height: ToolRail.topInset)
            RailButton(systemName: "plusminus", help: help("Changes", showing == .changes, "⌥⌘F"),
                       isActive: showing == .changes, badge: files) { model.toggleTool(.changes) }
            RailButton(systemName: "arrow.triangle.pull", help: help("Pull Request", showing == .pullRequest, "⌥⌘P"),
                       isActive: showing == .pullRequest, badge: pullRequests > 1 ? pullRequests : 0) { model.toggleTool(.pullRequest) }
            Spacer(minLength: 0)
        }
        .frame(width: ToolRail.width)
        .frame(maxHeight: .infinity)
        .background(DS.sidebar)
    }

    private func help(_ tool: String, _ showing: Bool, _ shortcut: String) -> String {
        "\(showing ? "Hide" : "Show") the session's \(tool) (\(shortcut))"
    }
}

/// The right rail's open tool, for the selected session.
struct RightToolPanel: View {
    @Environment(AppModel.self) private var model
    let tool: RightTool

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: tool == .changes ? "Changes" : "Pull Request") {
                IconButton(systemName: "minus", help: "Hide", size: 13) { model.toggleTool(tool) }
            }
            if let session = model.selectedSession {
                switch tool {
                case .changes: ChangesTool(session: session)
                case .pullRequest: SessionPullRequestTool(session: session)
                }
            } else {
                Text(model.selectedOverview == nil ? "No session selected." : "Select a session's tab to see its \(tool == .changes ? "changes" : "pull requests").")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                Spacer()
            }
        }
        .frame(width: ToolRail.rightPanelWidth)
        .frame(maxHeight: .infinity)
        .background(DS.sidebar)
    }
}

// MARK: - Status bar (the app)

/// Across the foot of the window: the status counts (click one to show only
/// those sessions) and plan usage (click for the details).
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingUsage = false

    var body: some View {
        HStack(spacing: 6) {
            statusCounts
            Spacer(minLength: 8)
            usageButton
        }
        .font(DS.font(12))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(DS.sidebar)
        .overlay(alignment: .top) { HorizontalRule() }
    }

    private var statusCounts: some View {
        let counts = model.footerStatusCounts
        return ForEach(SessionStatus.allCases, id: \.self) { status in
            let isActive = model.statusFilter == status
            Button { model.toggleStatusFilter(status) } label: {
                HStack(spacing: 5) {
                    StatusDot(status: status, size: 7)
                    Text("\(counts[status]) \(status.label)")
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(Capsule().fill(isActive ? DS.color(for: status).opacity(0.25) : .clear))
                .overlay(Capsule().stroke(isActive ? DS.color(for: status).opacity(0.7) : .clear, lineWidth: 1))
                .foregroundStyle(isActive ? DS.text : DS.muted)
                .opacity(model.statusFilter == nil || isActive ? 1 : 0.55)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(isActive ? "Show all sessions" : "Show only \(status.label) sessions")
        }
    }

    /// "Session 80% · Week 11%", with the credits badge when a limit is hit.
    private var usageButton: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let usage = model.usage?.current(at: context.date)
            let isStale = usage?.isStale(at: context.date, refreshInterval: AppModel.usageRefreshInterval) ?? false
            Button { showingUsage.toggle() } label: {
                HStack(spacing: 6) {
                    if let usage, usage.isUsingCredits {
                        UsageSection.creditsBadge("USING CREDITS", DS.orange)
                    } else if let usage, usage.isOutOfCredits {
                        UsageSection.creditsBadge("OUT OF CREDITS", DS.red)
                    }
                    if let usage, usage.fiveHour != nil || usage.sevenDay != nil {
                        if let window = usage.fiveHour { figure("Session", window) }
                        if usage.fiveHour != nil && usage.sevenDay != nil {
                            Text("·").foregroundStyle(DS.dim)
                        }
                        if let window = usage.sevenDay { figure("Week", window) }
                    } else {
                        Text("Plan usage").foregroundStyle(DS.dim)
                    }
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.dim)
                }
                .foregroundStyle(DS.muted)
                .opacity(isStale ? 0.6 : 1)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(showingUsage ? DS.border : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isStale ? "Plan usage (couldn't update)" : "Plan usage")
            .popover(isPresented: $showingUsage, arrowEdge: .top) {
                UsageSection(usage: model.usage)
                    .background(DS.input)
            }
        }
    }

    private func figure(_ title: String, _ window: UsageWindow) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(window.percentLabel)
                .font(DS.font(12, .bold))
                .foregroundStyle(UsageSection.color(for: window))
        }
    }
}
#endif
