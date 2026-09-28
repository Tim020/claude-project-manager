import Foundation

/// A tool on the left rail (design 8c). The left rail's tools cover
/// projects: the session tree, and their pull requests.
public enum LeftTool: String, Codable, CaseIterable, Sendable {
    case sessions, pullRequests
}

/// A tool on the right rail (design 8c). The right rail's tools cover the
/// selected session: the files it changed, and its pull requests.
public enum RightTool: String, Codable, CaseIterable, Sendable {
    case changes, pullRequest
}

/// Which tool each side of the window shows, and whether that side is open.
/// The rails always show; as in PyCharm or VS Code, clicking the tool that's
/// showing hides its side, and clicking another switches to it.
public struct ToolWindows: Codable, Equatable, Sendable {
    public var left: LeftTool = .sessions
    public var isLeftOpen = true
    public var right: RightTool = .changes
    public var isRightOpen = false
    /// Which pull requests the left rail's Pull Requests tool lists.
    public var pullRequestFilter: PullRequestFilter = .open
    /// Projects collapsed in the Pull Requests tool (their headers stay).
    public var collapsedPullRequestProjects: Set<UUID> = []

    public init(left: LeftTool = .sessions, isLeftOpen: Bool = true, right: RightTool = .changes, isRightOpen: Bool = false) {
        self.left = left
        self.isLeftOpen = isLeftOpen
        self.right = right
        self.isRightOpen = isRightOpen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown tool (from a newer version) falls back to the default.
        left = (try? c.decodeIfPresent(LeftTool.self, forKey: .left)) ?? .sessions
        isLeftOpen = try c.decodeIfPresent(Bool.self, forKey: .isLeftOpen) ?? true
        right = (try? c.decodeIfPresent(RightTool.self, forKey: .right)) ?? .changes
        isRightOpen = try c.decodeIfPresent(Bool.self, forKey: .isRightOpen) ?? false
        pullRequestFilter = (try? c.decodeIfPresent(PullRequestFilter.self, forKey: .pullRequestFilter)) ?? .open
        collapsedPullRequestProjects = try c.decodeIfPresent(Set<UUID>.self, forKey: .collapsedPullRequestProjects) ?? []
    }

    /// The tool showing on the left, or nil when that side is hidden.
    public var visibleLeft: LeftTool? { isLeftOpen ? left : nil }

    /// The tool showing on the right, or nil when that side is hidden.
    public var visibleRight: RightTool? { isRightOpen ? right : nil }

    /// A left rail button: shows its tool, or hides the side if it's showing.
    public mutating func toggle(_ tool: LeftTool) {
        if visibleLeft == tool {
            isLeftOpen = false
        } else {
            left = tool
            isLeftOpen = true
        }
    }

    /// A right rail button: shows its tool, or hides the side if it's showing.
    public mutating func toggle(_ tool: RightTool) {
        if visibleRight == tool {
            isRightOpen = false
        } else {
            right = tool
            isRightOpen = true
        }
    }
}

/// One project's pull requests in the left rail's Pull Requests tool.
public struct PullRequestPanelGroup: Identifiable, Equatable, Sendable {
    public var projectID: UUID
    public var name: String
    public var items: [PullRequestPanelItem]
    /// Pull requests have loaded for the project (so an empty list means none).
    public var hasLoaded: Bool
    /// Why the last load failed, if it did (what loaded before stays).
    public var error: String?
    /// Collapsed to its header (`items` are still filled in, for its count).
    public var isCollapsed = false

    public var id: UUID { projectID }
}

public struct PullRequestPanelItem: Identifiable, Equatable, Sendable {
    public var pullRequest: PullRequestInfo
    /// The session that opened it (else the first that reviewed it).
    public var sessionID: UUID?
    /// That session's folder's name.
    public var folder: String?

    public var id: String { pullRequest.key }
}

extension AppModel {
    public var toolWindows: ToolWindows { state.settings.toolWindows }

    public func toggleTool(_ tool: LeftTool) {
        var settings = state.settings
        settings.toolWindows.toggle(tool)
        updateSettings(settings)
        updateMenuFlags()
    }

    public func toggleTool(_ tool: RightTool) {
        var settings = state.settings
        settings.toolWindows.toggle(tool)
        updateSettings(settings)
        updateMenuFlags()
    }

    /// Sets which pull requests the Pull Requests tool lists (remembered).
    public func setPullRequestPanelFilter(_ filter: PullRequestFilter) {
        guard state.settings.toolWindows.pullRequestFilter != filter else { return }
        var settings = state.settings
        settings.toolWindows.pullRequestFilter = filter
        updateSettings(settings)
    }

    /// A project's header in the Pull Requests tool: collapses or expands its list.
    public func togglePullRequestPanelCollapsed(_ projectID: UUID) {
        var settings = state.settings
        if !settings.toolWindows.collapsedPullRequestProjects.insert(projectID).inserted {
            settings.toolWindows.collapsedPullRequestProjects.remove(projectID)
        }
        updateSettings(settings)
    }

    /// Collapse All / Expand All in the Pull Requests tool.
    public func setAllPullRequestPanelsCollapsed(_ collapsed: Bool) {
        var settings = state.settings
        settings.toolWindows.collapsedPullRequestProjects = collapsed ? Set(workspace.projects.map(\.id)) : []
        updateSettings(settings)
    }

    /// The left rail's Pull Requests: for each project whose pull requests
    /// are tracked, the ones the tool's filter matches that its sessions
    /// opened or reviewed (plus, with "Include PRs without a session", its
    /// other open ones). Open ones come first, most urgent first; closed and
    /// merged ones follow if they were updated within the sidebar's activity
    /// window.
    public func pullRequestPanel() -> [PullRequestPanelGroup] {
        let since = settings.activitySince(now: now())
        let filter = toolWindows.pullRequestFilter
        let collapsed = toolWindows.collapsedPullRequestProjects
        return workspace.projects.filter { tracksPullRequests(projectID: $0.id) }.map { project in
            let known = projectPullRequests[project.id]
            var open: [(PullRequestInfo, Session?)] = []
            var done: [(PullRequestInfo, Session?)] = []
            for pullRequest in (known?.items ?? []).sortedByUpdate where filter.matches(pullRequest) {
                let session = sessions(for: pullRequest, projectID: project.id).first
                if pullRequest.isOpen {
                    guard session != nil || includeUnlinkedPullRequests else { continue }
                    open.append((pullRequest, session))
                } else {
                    // Closed and merged ones only if a session here acted on them.
                    guard session != nil else { continue }
                    if let since, (pullRequest.updatedAt ?? .distantPast) < since { continue }
                    done.append((pullRequest, session))
                }
            }
            let sessionByKey = Dictionary(open.map { ($0.0.key, $0.1) }, uniquingKeysWith: { first, _ in first })
            let ordered = PullRequestInfo.mostUrgentFirst(open.map(\.0)).map { ($0, sessionByKey[$0.key] ?? nil) } + done
            let items = ordered.map { pullRequest, session in
                PullRequestPanelItem(pullRequest: pullRequest, sessionID: session?.id,
                                     folder: session.flatMap { workspace.group(of: $0.id) }.map(workspace.name(of:)))
            }
            return PullRequestPanelGroup(projectID: project.id, name: project.name, items: items,
                                         hasLoaded: known?.hasLoaded ?? false, error: known?.error,
                                         isCollapsed: collapsed.contains(project.id))
        }
    }

    /// What a loaded project in the Pull Requests tool says when the filter
    /// leaves nothing to list.
    public var pullRequestPanelNoMatchText: String {
        switch toolWindows.pullRequestFilter {
        case .open: return "No open pull requests."
        case .needsAttention: return "None need attention."
        case .merged: return "No recently merged pull requests."
        case .all: return "No pull requests to show."
        }
    }

    /// What the Pull Requests tool says when it lists no projects.
    public var pullRequestPanelEmptyText: String {
        if workspace.projects.isEmpty { return "No projects yet." }
        // Only once gh has said so for every project.
        if workspace.projects.allSatisfy({ projectPullRequests[$0.id]?.isNotGitHub == true }) {
            return "None of your projects are on GitHub."
        }
        if case .unchecked = environment.githubCLI { return "Checking GitHub…" }
        return "No pull requests to show."
    }
}
