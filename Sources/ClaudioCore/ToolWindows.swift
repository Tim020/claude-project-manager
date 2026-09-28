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

    /// The left rail's Pull Requests: for each project whose pull requests
    /// are tracked, the ones its sessions opened or reviewed (plus, with
    /// "Include PRs without a session", its other open ones). Open ones come
    /// first, most urgent first; closed and merged ones follow if they were
    /// updated within the sidebar's activity window.
    public func pullRequestPanel() -> [PullRequestPanelGroup] {
        let since = settings.activitySince(now: now())
        return workspace.projects.filter { tracksPullRequests(projectID: $0.id) }.map { project in
            let known = projectPullRequests[project.id]
            var open: [PullRequestPanelItem] = []
            var done: [PullRequestPanelItem] = []
            for pullRequest in (known?.items ?? []).sortedByUpdate {
                let session = sessions(for: pullRequest, projectID: project.id).first
                if pullRequest.isOpen {
                    guard session != nil || includeUnlinkedPullRequests else { continue }
                } else {
                    guard session != nil else { continue }
                    if let since, (pullRequest.updatedAt ?? .distantPast) < since { continue }
                }
                let item = PullRequestPanelItem(pullRequest: pullRequest, sessionID: session?.id,
                                                folder: session.flatMap { workspace.group(of: $0.id) }.map(workspace.name(of:)))
                if pullRequest.isOpen { open.append(item) } else { done.append(item) }
            }
            let urgentOpen = open.enumerated().sorted {
                ($0.element.pullRequest.attention.urgency, $0.offset) < ($1.element.pullRequest.attention.urgency, $1.offset)
            }.map(\.element)
            return PullRequestPanelGroup(projectID: project.id, name: project.name, items: urgentOpen + done,
                                         hasLoaded: known?.hasLoaded ?? false)
        }
    }
}
