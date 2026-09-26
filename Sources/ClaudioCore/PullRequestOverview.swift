import Foundation

/// What the detail area shows instead of a session: a project's pull
/// requests, or one folder's.
public enum Overview: Hashable, Sendable {
    case project(UUID)
    case folder(SessionGroup)
}

/// The project overview's filter tabs.
public enum PullRequestFilter: String, CaseIterable, Sendable {
    case needsAttention = "Needs Attention"
    case open = "Open"
    case merged = "Merged"
    case all = "All"

    public func matches(_ pullRequest: PullRequestInfo) -> Bool {
        switch self {
        case .needsAttention: return pullRequest.needsAttention
        case .open: return pullRequest.isOpen
        case .merged: return pullRequest.state == .merged
        case .all: return true
        }
    }
}

/// A project's pull requests from GitHub, as last loaded.
public struct ProjectPullRequests: Equatable, Sendable {
    public var repository: GitHubCLI.Repository?
    public var items: [PullRequestInfo]
    public var updatedAt: Date?
    /// Why they couldn't be loaded, if they couldn't.
    public var error: String?

    public init(repository: GitHubCLI.Repository? = nil, items: [PullRequestInfo] = [], updatedAt: Date? = nil, error: String? = nil) {
        self.repository = repository
        self.items = items
        self.updatedAt = updatedAt
        self.error = error
    }

    public func item(forURL url: String) -> PullRequestInfo? {
        guard let key = PullRequestKey.key(url) else { return nil }
        return items.first { $0.key == key }
    }
}

/// One group in the project overview: a folder (or Unfiled) and the pull
/// requests its sessions worked on, or the ones no session did.
public struct PullRequestGroup: Identifiable, Equatable, Sendable {
    /// nil for pull requests without a session.
    public var group: SessionGroup?
    public var name: String
    public var pullRequests: [PullRequestInfo]

    public var id: String {
        switch group {
        case .folder(let id): return id.uuidString
        case .unfiled(let projectID): return "unfiled-\(projectID.uuidString)"
        case nil: return "none"
        }
    }

    public var isUnfiled: Bool {
        if case .unfiled = group { return true }
        return false
    }
}

/// Ties pull requests to the sessions that mention them (`pullRequestURLs`).
public enum PullRequestOverview {
    /// The project's (non-archived) sessions that mention the pull request.
    /// Sessions that wrote code come before ones that reviewed it.
    public static func sessions(for pullRequest: PullRequestInfo, in workspace: Workspace, projectID: UUID) -> [Session] {
        let linked = workspace.sessions.filter { session in
            session.projectID == projectID && !session.isArchived
                && session.pullRequestURLs.contains { PullRequestKey.key($0) == pullRequest.key }
        }
        return linked.filter { !isReviewer($0) } + linked.filter(isReviewer)
    }

    public static func isReviewer(_ session: Session) -> Bool {
        session.role.rawValue.caseInsensitiveCompare(SessionRole.review.rawValue) == .orderedSame
    }

    /// Where a pull request belongs: the group of the first session that
    /// mentions it (preferring one that wrote code).
    public static func group(of pullRequest: PullRequestInfo, in workspace: Workspace, projectID: UUID) -> SessionGroup? {
        sessions(for: pullRequest, in: workspace, projectID: projectID).first.flatMap { workspace.group(of: $0.id) }
    }

    /// Pull requests the filter matches (and, unless `includeUnlinked`, that
    /// a session mentions), grouped by folder in sidebar order, then Unfiled,
    /// then "No Session". Most recently updated first within each.
    public static func groups(_ pullRequests: [PullRequestInfo], workspace: Workspace, projectID: UUID,
                              filter: PullRequestFilter, includeUnlinked: Bool) -> [PullRequestGroup] {
        guard let project = workspace.project(projectID) else { return [] }
        var byGroup: [SessionGroup?: [PullRequestInfo]] = [:]
        for pullRequest in sorted(pullRequests) where filter.matches(pullRequest) {
            let group = self.group(of: pullRequest, in: workspace, projectID: projectID)
            if group == nil && !includeUnlinked { continue }
            byGroup[group, default: []].append(pullRequest)
        }
        var order: [SessionGroup?] = project.folders.map { .folder($0.id) }
        order.append(.unfiled(projectID: projectID))
        order.append(nil)
        return order.compactMap { group in
            guard let items = byGroup[group], !items.isEmpty else { return nil }
            return PullRequestGroup(group: group, name: group.map(workspace.name(of:)) ?? "No Session", pullRequests: items)
        }
    }

    /// How many pull requests each filter tab would show.
    public static func count(_ pullRequests: [PullRequestInfo], workspace: Workspace, projectID: UUID,
                             filter: PullRequestFilter, includeUnlinked: Bool) -> Int {
        pullRequests.filter { filter.matches($0) && (includeUnlinked || group(of: $0, in: workspace, projectID: projectID) != nil) }.count
    }

    /// The pull requests a folder's sessions mention, open ones first.
    public static func pullRequests(in group: SessionGroup, workspace: Workspace, known: ProjectPullRequests?) -> [PullRequestInfo] {
        guard let known, let projectID = workspace.projectID(of: group) else { return [] }
        let items = known.items.filter { self.group(of: $0, in: workspace, projectID: projectID) == group }
        return items.filter(\.isOpen).sortedByUpdate + items.filter { !$0.isOpen }.sortedByUpdate
    }

    /// A session's pull requests, in the order it mentioned them, as far as
    /// they've been loaded.
    public static func pullRequests(of session: Session, known: ProjectPullRequests?) -> [PullRequestInfo] {
        guard let known else { return [] }
        var seen = Set<String>()
        return session.pullRequestURLs.compactMap { url in
            guard let item = known.item(forURL: url), seen.insert(item.key).inserted else { return nil }
            return item
        }
    }

    static func sorted(_ items: [PullRequestInfo]) -> [PullRequestInfo] { items.sortedByUpdate }
}

extension Array where Element == PullRequestInfo {
    /// Most recently updated first.
    var sortedByUpdate: [PullRequestInfo] {
        sorted { ($0.updatedAt ?? .distantPast, $0.number) > ($1.updatedAt ?? .distantPast, $1.number) }
    }
}
