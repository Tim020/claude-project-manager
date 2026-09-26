import Foundation

/// Pull Requests overviews (design 5): each project's pull requests from
/// GitHub via `gh`, tied to the sessions that mention them.
extension AppModel {
    /// How long loaded pull requests stay fresh before a refresh reloads them.
    public static let pullRequestRefreshInterval: TimeInterval = 120
    /// Open pull requests fetched per project; recent ones of any state too.
    static let openPullRequestLimit = 100
    static let recentPullRequestLimit = 40
    /// Pull requests sessions mention but the lists missed, fetched one by one.
    static let extraPullRequestLimit = 20

    /// Why pull requests can't be loaded, when gh isn't set up.
    public var gitHubCLIProblem: String? {
        switch environment.githubCLI {
        case .notInstalled: return "Pull requests come from the GitHub CLI (gh), which isn't installed."
        case .signedOut: return "Pull requests come from the GitHub CLI (gh), which isn't signed in."
        case .unchecked, .signedIn: return nil
        }
    }

    // MARK: Navigation

    public func showOverview(_ overview: Overview) {
        self.overview = overview
        if let projectID = projectID(of: overview) {
            Task { await refreshPullRequests(projectID) }
        }
    }

    /// The overview, unless its project or folder has since gone.
    public var activeOverview: Overview? {
        guard let overview, let projectID = projectID(of: overview), workspace.project(projectID) != nil else { return nil }
        return overview
    }

    public func closeOverview() {
        overview = nil
    }

    public func projectID(of overview: Overview) -> UUID? {
        switch overview {
        case .project(let id): return id
        case .folder(let group): return workspace.projectID(of: group)
        }
    }

    // MARK: Reading

    public func pullRequests(forProject projectID: UUID) -> ProjectPullRequests? {
        projectPullRequests[projectID]
    }

    /// A session's pull requests, as far as they've been loaded.
    public func pullRequests(ofSession sessionID: UUID) -> [PullRequestInfo] {
        guard let session = workspace.session(sessionID) else { return [] }
        return PullRequestOverview.pullRequests(of: session, known: projectPullRequests[session.projectID])
    }

    /// The pull requests a folder's (or Unfiled's) sessions mention.
    public func pullRequests(in group: SessionGroup) -> [PullRequestInfo] {
        guard let projectID = workspace.projectID(of: group) else { return [] }
        return PullRequestOverview.pullRequests(in: group, workspace: workspace, known: projectPullRequests[projectID])
    }

    public func sessions(for pullRequest: PullRequestInfo, projectID: UUID) -> [Session] {
        PullRequestOverview.sessions(for: pullRequest, in: workspace, projectID: projectID)
    }

    public func pullRequestGroups(projectID: UUID) -> [PullRequestGroup] {
        PullRequestOverview.groups(projectPullRequests[projectID]?.items ?? [], workspace: workspace, projectID: projectID,
                                   filter: pullRequestFilter, includeUnlinked: includeUnlinkedPullRequests)
    }

    public func pullRequestCount(projectID: UUID, filter: PullRequestFilter) -> Int {
        PullRequestOverview.count(projectPullRequests[projectID]?.items ?? [], workspace: workspace, projectID: projectID,
                                  filter: filter, includeUnlinked: includeUnlinkedPullRequests)
    }

    /// Whether the sidebar shows a project's Pull Requests row: when gh can
    /// load them, or a session has mentioned one.
    public func showsPullRequestsRow(projectID: UUID) -> Bool {
        if case .signedIn = environment.githubCLI { return true }
        if projectPullRequests[projectID]?.items.isEmpty == false { return true }
        return workspace.sessions.contains { $0.projectID == projectID && !$0.isArchived && !$0.pullRequestURLs.isEmpty }
    }

    // MARK: Loading

    /// Loads a project's pull requests: its open ones, its recent ones of any
    /// state, and any others its sessions mention. Skipped while fresh
    /// unless forced.
    public func refreshPullRequests(_ projectID: UUID, force: Bool = false) async {
        guard gitHubCLIProblem == nil, let project = workspace.project(projectID), let gh = locateGitHubCLI(),
              !refreshingPullRequests.contains(projectID) else { return }
        if !force, let updated = projectPullRequests[projectID]?.updatedAt,
           now().timeIntervalSince(updated) < AppModel.pullRequestRefreshInterval {
            return
        }
        refreshingPullRequests.insert(projectID)
        loadingPullRequests.insert(projectID)
        defer {
            refreshingPullRequests.remove(projectID)
            loadingPullRequests.remove(projectID)
        }
        let directory = project.path
        func runGitHub(_ args: [String], key: String) async -> CommandResult {
            await run(GitHubCLI.command(args, in: directory, gh: gh), logOnlyChanges: true, changeKey: "gh-\(key)|\(directory)")
        }

        var loaded = projectPullRequests[projectID] ?? ProjectPullRequests()
        if loaded.repository == nil {
            let result = await runGitHub(["repo", "view", "--json", "nameWithOwner,url"], key: "repo")
            guard result.exitCode == 0, let repository = GitHubCLI.parseRepository(result.output) else {
                loaded.error = Self.firstLine(result.errorOutput) ?? "This project isn't a GitHub repository."
                loaded.updatedAt = now()
                projectPullRequests[projectID] = loaded
                return
            }
            loaded.repository = repository
        }

        let fields = GitHubCLI.overviewFields
        let open = await runGitHub(["pr", "list", "--state", "open", "--limit", "\(AppModel.openPullRequestLimit)", "--json", fields], key: "open")
        let recent = await runGitHub(["pr", "list", "--state", "all", "--limit", "\(AppModel.recentPullRequestLimit)", "--json", fields], key: "recent")
        guard open.exitCode == 0, let openItems = GitHubCLI.parsePullRequests(open.output) else {
            loaded.error = Self.firstLine(open.errorOutput) ?? "Couldn't load pull requests."
            loaded.updatedAt = now()
            projectPullRequests[projectID] = loaded
            return
        }
        var items = openItems
        var keys = Set(items.map(\.key))
        for item in GitHubCLI.parsePullRequests(recent.output) ?? [] where keys.insert(item.key).inserted {
            items.append(item)
        }

        // Pull requests sessions mention that neither list had (older, or
        // in another repository).
        let mentioned = workspace.sessions.filter { $0.projectID == projectID && !$0.isArchived }.flatMap(\.pullRequestURLs)
        var missing: [String] = []
        for url in mentioned {
            guard let key = PullRequestKey.key(url), !keys.contains(key) else { continue }
            keys.insert(key)
            missing.append(url)
        }
        let previous = projectPullRequests[projectID]
        for url in missing.prefix(AppModel.extraPullRequestLimit) {
            // Merged and closed ones don't change: keep what's known.
            if let known = previous?.item(forURL: url), !known.isOpen {
                items.append(known)
                continue
            }
            let result = await runGitHub(["pr", "view", url, "--json", fields], key: "view-\(url)")
            if result.exitCode == 0, let item = GitHubCLI.parsePullRequestInfo(result.output) { items.append(item) }
        }

        loaded.items = items
        loaded.error = nil
        loaded.updatedAt = now()
        projectPullRequests[projectID] = loaded
    }

    /// Every project's pull requests (sidebar chips and counts).
    public func refreshAllPullRequests(force: Bool = false) async {
        for project in workspace.projects where showsPullRequestsRow(projectID: project.id) {
            await refreshPullRequests(project.id, force: force)
        }
    }

    /// Unresolved review threads for open pull requests, via `gh api graphql`.
    public func loadReviewThreads(for pullRequests: [PullRequestInfo], force: Bool = false) async {
        guard gitHubCLIProblem == nil, let gh = locateGitHubCLI() else { return }
        for pullRequest in pullRequests where pullRequest.isOpen || reviewThreads[pullRequest.key] == nil {
            if !force, let loaded = reviewThreadsLoaded[pullRequest.key],
               now().timeIntervalSince(loaded) < AppModel.pullRequestRefreshInterval {
                continue
            }
            guard let args = GitHubCLI.reviewThreadsArguments(url: pullRequest.url) else { continue }
            reviewThreadsLoaded[pullRequest.key] = now()
            let result = await run(GitHubCLI.command(args, in: home, gh: gh), logOnlyChanges: true, changeKey: "gh-threads|\(pullRequest.key)")
            if result.exitCode == 0, let threads = GitHubCLI.parseReviewThreads(result.output), reviewThreads[pullRequest.key] != threads {
                reviewThreads[pullRequest.key] = threads
            }
        }
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
