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

    /// Opens an overview as a tab in the focused pane (or shows its tab where
    /// it's open), and loads its pull requests.
    public func showOverview(_ overview: Overview) {
        var opened: UUID?
        updatePanes { opened = $0.openOverview(overview) }
        guard opened != nil, let projectID = workspace.projectID(of: overview) else { return }
        Task { await refreshPullRequests(projectID) }
    }

    /// The overview the focused tab shows, if it's an overview tab.
    public var selectedOverview: Overview? {
        selectedSessionID.flatMap { workspace.overviewTab($0)?.overview }
    }

    /// An overview tab's title and the place it's for ("Pull Requests",
    /// "DigiScript").
    public func title(of overview: Overview) -> (title: String, place: String) {
        switch overview {
        case .project(let id): return ("Pull Requests", workspace.project(id)?.name ?? "")
        case .folder(let group): return ("Pull Requests", workspace.name(of: group))
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
        PullRequestOverview.sessions(for: pullRequest, in: workspace, projectID: projectID, repository: repository(forProject: projectID))
    }

    /// The folder a pull request belongs to: its opener's, else its first
    /// reviewer's. Nil when no session acted on it.
    public func group(of pullRequest: PullRequestInfo, projectID: UUID) -> SessionGroup? {
        PullRequestOverview.group(of: pullRequest, in: workspace, projectID: projectID, repository: repository(forProject: projectID))
    }

    /// What a session did to a pull request (opened or reviewed it).
    public func action(of session: Session, on pullRequest: PullRequestInfo) -> PullRequestLink.Action? {
        PullRequestOverview.action(of: session, on: pullRequest, repository: repository(forProject: session.projectID))
    }

    public func pullRequestGroups(projectID: UUID) -> [PullRequestGroup] {
        PullRequestOverview.groups(projectPullRequests[projectID], workspace: workspace, projectID: projectID,
                                   filter: pullRequestFilter, includeUnlinked: includeUnlinkedPullRequests)
    }

    public func pullRequestCount(projectID: UUID, filter: PullRequestFilter) -> Int {
        PullRequestOverview.count(projectPullRequests[projectID], workspace: workspace, projectID: projectID,
                                  filter: filter, includeUnlinked: includeUnlinkedPullRequests)
    }

    /// The project's GitHub repository ("owner/repo"): as gh reports it,
    /// else from its `origin` remote. Nil when it isn't a GitHub repository
    /// (or hasn't been looked up yet).
    public func repository(forProject projectID: UUID) -> String? {
        projectPullRequests[projectID]?.repository?.nameWithOwner ?? remoteRepositories[projectID]
    }

    /// The pull requests a session opened or reviewed in its project's
    /// repository, with their URLs. Others (in other repositories) aren't
    /// its project's, so they're left out; so is everything while the
    /// repository isn't known.
    public func pullRequestLinks(ofSession sessionID: UUID) -> [SessionPullRequest] {
        guard let session = workspace.session(sessionID), let repository = repository(forProject: session.projectID) else { return [] }
        let prefix = repository.lowercased() + "#"
        var result: [SessionPullRequest] = []
        for link in session.pullRequests {
            guard let key = link.key(in: repository), key.hasPrefix(prefix),
                  let url = link.url(in: repository), let number = Int(key.dropFirst(prefix.count)) else { continue }
            // "#12" and its URL are the same pull request; opening beats reviewing.
            if let index = result.firstIndex(where: { $0.number == number }) {
                if link.action == .opened { result[index].action = .opened }
            } else {
                result.append(SessionPullRequest(url: url, number: number, action: link.action))
            }
        }
        return result
    }

    /// Whether the sidebar shows a project's Pull Requests row: when gh can
    /// load them, or a session has opened or reviewed one.
    public func showsPullRequestsRow(projectID: UUID) -> Bool {
        if case .signedIn = environment.githubCLI { return true }
        if projectPullRequests[projectID]?.items.isEmpty == false { return true }
        return workspace.sessions.contains { $0.projectID == projectID && !$0.isArchived && !pullRequestLinks(ofSession: $0.id).isEmpty }
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
            // Known from now on, for resolving sessions' "#123" links below.
            projectPullRequests[projectID] = loaded
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

        // Pull requests sessions opened or reviewed that neither list had
        // (older ones). Only this repository's: others aren't the project's.
        let linked = workspace.sessions.filter { $0.projectID == projectID && !$0.isArchived }
            .flatMap { pullRequestLinks(ofSession: $0.id) }
        var missing: [String] = []
        for link in linked {
            guard let key = PullRequestKey.key(link.url), !keys.contains(key) else { continue }
            keys.insert(key)
            missing.append(link.url)
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
        await loadRemoteRepositories()
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

    /// Each project's GitHub repository from its `origin` remote, once, so
    /// sessions' pull requests can be told apart from other repositories'
    /// even without gh.
    func loadRemoteRepositories() async {
        for project in workspace.projects where remoteRepositories[project.id] == nil && !checkedRemotes.contains(project.id) {
            checkedRemotes.insert(project.id)
            let result = await run(GitChanges.command(["remote", "get-url", "origin"], in: project.path, git: gitExecutable),
                                   logOnlyChanges: true, changeKey: "git-remote|\(project.path)")
            if result.exitCode == 0, let repository = GitRemote.repository(fromURL: result.output) {
                remoteRepositories[project.id] = repository
            }
        }
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
