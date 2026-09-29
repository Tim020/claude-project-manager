import Foundation

/// A tab that shows pull requests rather than a session: a project's, or
/// one folder's (or Unfiled's).
public enum Overview: Hashable, Codable, Sendable {
    case project(UUID)
    case folder(SessionGroup)
}

/// What a pane's tab shows.
public enum PaneTab: Equatable, Identifiable, Sendable {
    case session(Session)
    case overview(OverviewTab)

    public var id: UUID {
        switch self {
        case .session(let session): return session.id
        case .overview(let tab): return tab.id
        }
    }

    public var session: Session? {
        if case .session(let session) = self { return session }
        return nil
    }
}

/// An open overview tab. Its id is the tab's id in the panes, alongside
/// session ids.
public struct OverviewTab: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var overview: Overview

    public init(id: UUID = UUID(), overview: Overview) {
        self.id = id
        self.overview = overview
    }
}

/// The project overview's filter tabs, and the Pull Requests tool's filter.
public enum PullRequestFilter: String, CaseIterable, Codable, Sendable {
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
    /// When the pull requests last loaded (what "Updated 2m ago" says).
    public var updatedAt: Date?
    /// When a load was last tried, successful or not (for spacing out retries).
    public var attemptedAt: Date?
    /// What went wrong on the last try, if anything. `items` are then
    /// whatever loaded before.
    public var error: String?
    /// gh found no GitHub repository here: it isn't polled again (the
    /// refresh button still tries).
    public var isNotGitHub: Bool
    /// How many pull requests GitHub has, by state; `items` holds only the
    /// open and most recent ones. Nil until they've loaded.
    public var totals: GitHubCLI.PullRequestTotals?
    /// Every pull request, without details (`loadPullRequestHistory`),
    /// loaded when a list needs more than the open and recent ones. `items`
    /// includes the ones the other lists don't have.
    public var history: [PullRequestInfo] = []
    /// When the history was last tried, successful or not.
    public var historyLoadedAt: Date?
    /// GitHub's total when the history loaded: it reloads only past this.
    public var historyTotal: Int?

    public init(repository: GitHubCLI.Repository? = nil, items: [PullRequestInfo] = [], updatedAt: Date? = nil,
                attemptedAt: Date? = nil, error: String? = nil, isNotGitHub: Bool = false,
                totals: GitHubCLI.PullRequestTotals? = nil) {
        self.repository = repository
        self.items = items
        self.totals = totals
        self.updatedAt = updatedAt
        self.attemptedAt = attemptedAt ?? updatedAt
        self.error = error
        self.isNotGitHub = isNotGitHub
    }

    /// Something has loaded, even if the last refresh failed.
    public var hasLoaded: Bool { updatedAt != nil }

    /// GitHub's total for a filter, when it has one. Needs Attention is
    /// worked out here, from the loaded (open) pull requests.
    public func total(for filter: PullRequestFilter) -> Int? {
        guard let totals else { return nil }
        switch filter {
        case .needsAttention: return nil
        case .open: return totals.open
        case .merged: return totals.merged
        case .all: return totals.all
        }
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

/// Ties pull requests to the sessions that opened or reviewed them
/// (`Session.pullRequests`), within the project's repository ("owner/repo").
public enum PullRequestOverview {
    /// What a session did to a pull request, if anything.
    public static func action(of session: Session, on pullRequest: PullRequestInfo, repository: String?) -> PullRequestLink.Action? {
        let actions = session.pullRequests.filter { $0.key(in: repository) == pullRequest.key }.map(\.action)
        if actions.contains(.opened) { return .opened }
        return actions.first
    }

    /// The project's (non-archived) sessions that acted on the pull request:
    /// the one that opened it first, then ones that reviewed it.
    public static func sessions(for pullRequest: PullRequestInfo, in workspace: Workspace, projectID: UUID,
                                repository: String?) -> [Session] {
        let linked = workspace.sessions.compactMap { session -> (Session, PullRequestLink.Action)? in
            guard session.projectID == projectID, !session.isArchived,
                  let action = action(of: session, on: pullRequest, repository: repository) else { return nil }
            return (session, action)
        }
        return linked.filter { $0.1 == .opened }.map(\.0) + linked.filter { $0.1 == .reviewed }.map(\.0)
    }

    /// Where a pull request belongs: the group of the session that opened it,
    /// else of the first that reviewed it.
    public static func group(of pullRequest: PullRequestInfo, in workspace: Workspace, projectID: UUID,
                             repository: String?) -> SessionGroup? {
        sessions(for: pullRequest, in: workspace, projectID: projectID, repository: repository).first
            .flatMap { workspace.group(of: $0.id) }
    }

    /// Pull requests the filter matches (and, unless `includeUnlinked`, that
    /// a session acted on), grouped by folder in sidebar order, then Unfiled,
    /// then "No Session". Most recently updated first within each.
    public static func groups(_ known: ProjectPullRequests?, workspace: Workspace, projectID: UUID,
                              filter: PullRequestFilter, includeUnlinked: Bool) -> [PullRequestGroup] {
        guard let project = workspace.project(projectID), let known else { return [] }
        let repository = known.repository?.nameWithOwner
        var byGroup: [SessionGroup?: [PullRequestInfo]] = [:]
        for pullRequest in known.items.sortedByUpdate where filter.matches(pullRequest) {
            let group = self.group(of: pullRequest, in: workspace, projectID: projectID, repository: repository)
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
    public static func count(_ known: ProjectPullRequests?, workspace: Workspace, projectID: UUID,
                             filter: PullRequestFilter, includeUnlinked: Bool) -> Int {
        let loaded = loadedCount(known, workspace: workspace, projectID: projectID, filter: filter, includeUnlinked: includeUnlinked)
        // Counting every pull request: GitHub's total, since only the open
        // and most recent ones load. Never fewer than are listed.
        guard includeUnlinked, let total = known?.total(for: filter) else { return loaded }
        return max(total, loaded)
    }

    /// How many of the loaded pull requests a filter lists.
    public static func loadedCount(_ known: ProjectPullRequests?, workspace: Workspace, projectID: UUID,
                                   filter: PullRequestFilter, includeUnlinked: Bool) -> Int {
        guard let known else { return 0 }
        let repository = known.repository?.nameWithOwner
        return known.items.filter { pullRequest in
            filter.matches(pullRequest)
                && (includeUnlinked || group(of: pullRequest, in: workspace, projectID: projectID, repository: repository) != nil)
        }.count
    }

    /// The pull requests a folder's sessions opened (or reviewed, when no
    /// session opened them), open ones first.
    public static func pullRequests(in group: SessionGroup, workspace: Workspace, known: ProjectPullRequests?) -> [PullRequestInfo] {
        guard let known, let projectID = workspace.projectID(of: group) else { return [] }
        let repository = known.repository?.nameWithOwner
        let items = known.items.filter { self.group(of: $0, in: workspace, projectID: projectID, repository: repository) == group }
        return items.filter(\.isOpen).sortedByUpdate + items.filter { !$0.isOpen }.sortedByUpdate
    }

    /// A session's pull requests, in the order it acted on them, as far as
    /// they've been loaded.
    public static func pullRequests(of session: Session, known: ProjectPullRequests?) -> [PullRequestInfo] {
        guard let known else { return [] }
        let repository = known.repository?.nameWithOwner
        var seen = Set<String>()
        return session.pullRequests.compactMap { link in
            guard let key = link.key(in: repository), let item = known.items.first(where: { $0.key == key }),
                  seen.insert(key).inserted else { return nil }
            return item
        }
    }
}

extension Array where Element == PullRequestInfo {
    /// Most recently updated first.
    var sortedByUpdate: [PullRequestInfo] {
        sorted { ($0.updatedAt ?? .distantPast, $0.number) > ($1.updatedAt ?? .distantPast, $1.number) }
    }
}
