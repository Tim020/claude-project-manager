import Foundation

/// Pull Requests overviews (design 5): each project's pull requests from
/// GitHub via `gh`, tied to the sessions that opened or reviewed them.
extension AppModel {
    /// How long loaded pull requests stay fresh before a refresh reloads them.
    public static let pullRequestRefreshInterval: TimeInterval = 120
    /// Open pull requests fetched per project; recent ones of any state too.
    static let openPullRequestLimit = 100
    static let recentPullRequestLimit = 40
    /// Pull requests sessions acted on but the lists missed, fetched one by one.
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

    /// The pull requests that belong to a folder (or Unfiled): the ones its
    /// sessions opened, or reviewed when no session here opened them.
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

    /// Whether a project's pull requests are loaded and polled, and listed in
    /// the left rail's Pull Requests tool: when some
    /// have loaded, when gh can load them (unless it found no GitHub
    /// repository), or when a session has opened or reviewed one.
    public func tracksPullRequests(projectID: UUID) -> Bool {
        if projectPullRequests[projectID]?.items.isEmpty == false { return true }
        if case .signedIn = environment.githubCLI, projectPullRequests[projectID]?.isNotGitHub != true { return true }
        return workspace.sessions.contains { $0.projectID == projectID && !$0.isArchived && !pullRequestLinks(ofSession: $0.id).isEmpty }
    }

    // MARK: Loading

    /// Loads a project's pull requests: its open ones, its recent ones of any
    /// state, and up to `extraPullRequestLimit` older ones its sessions
    /// opened or reviewed. Skipped if tried recently, unless forced. A
    /// failure keeps what loaded before, with the error. Forced (the refresh
    /// button), it also reloads the review threads on screen.
    public func refreshPullRequests(_ projectID: UUID, force: Bool = false) async {
        guard await loadPullRequests(projectID, force: force), force else { return }
        // After "Updating…" has cleared: threads load one by one.
        let shown = (projectPullRequests[projectID]?.items ?? []).filter { shownReviewThreads[$0.key, default: 0] > 0 }
        await loadReviewThreads(for: shown, force: true)
    }

    /// The load itself; false if it didn't run (fresh, already running, or
    /// gh isn't set up).
    private func loadPullRequests(_ projectID: UUID, force: Bool) async -> Bool {
        guard gitHubCLIProblem == nil, let project = workspace.project(projectID), let gh = locateGitHubCLI(),
              !refreshingPullRequests.contains(projectID) else { return false }
        let previous = projectPullRequests[projectID]
        if !force, let tried = previous?.attemptedAt, now().timeIntervalSince(tried) < AppModel.pullRequestRefreshInterval {
            return false
        }
        if !force, previous?.isNotGitHub == true { return false }
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

        var loaded = previous ?? ProjectPullRequests()
        loaded.attemptedAt = now()
        if loaded.repository == nil {
            await loadRemoteRepositories()
            let result = await runGitHub(["repo", "view", "--json", "nameWithOwner,url"], key: "repo")
            guard let repository = GitHubCLI.parseRepository(result.output), result.exitCode == 0 else {
                if result.exitCode != 0 {
                    loaded.error = Self.firstLine(result.errorOutput) ?? "gh repo view failed."
                    // Only gh saying so means it isn't on GitHub: then stop
                    // polling it (and logging the same failure every 2
                    // minutes). Anything else (offline, VPN not up yet) is
                    // retried after the usual interval.
                    loaded.isNotGitHub = GitHubCLI.isNotGitHubRepository(result.errorOutput)
                } else {
                    loaded.error = "Couldn't read the repository from gh (gh repo view)."
                }
                projectPullRequests[projectID] = loaded
                return true
            }
            loaded.repository = repository
            loaded.isNotGitHub = false
            // Known from now on, for resolving sessions' "#123" links below.
            projectPullRequests[projectID] = loaded
        }

        let fields = GitHubCLI.overviewFields
        let open = await runGitHub(["pr", "list", "--state", "open", "--limit", "\(AppModel.openPullRequestLimit)", "--json", fields], key: "open")
        guard open.exitCode == 0, let openItems = GitHubCLI.parsePullRequests(open.output) else {
            loaded.error = "Couldn't refresh: " + (Self.firstLine(open.errorOutput) ?? "gh pr list failed.")
            projectPullRequests[projectID] = loaded
            return true
        }
        var problems: [String] = []
        var items = openItems
        var keys = Set(items.map(\.key))
        let recent = await runGitHub(["pr", "list", "--state", "all", "--limit", "\(AppModel.recentPullRequestLimit)", "--json", fields], key: "recent")
        if recent.exitCode == 0, let recentItems = GitHubCLI.parsePullRequests(recent.output) {
            for item in recentItems where keys.insert(item.key).inserted { items.append(item) }
        } else {
            // Keep the merged and closed ones that loaded before.
            for item in previous?.items ?? [] where !item.isOpen && keys.insert(item.key).inserted { items.append(item) }
            problems.append("recent pull requests: " + (Self.firstLine(recent.errorOutput) ?? "gh pr list failed"))
        }

        // Pull requests sessions opened or reviewed that neither list had
        // (older ones). Only this repository's: others aren't the project's.
        // Merged and closed ones don't change, so known ones are kept as they
        // are; the limit is on the ones that need fetching.
        let linked = workspace.sessions.filter { $0.projectID == projectID && !$0.isArchived }
            .flatMap { pullRequestLinks(ofSession: $0.id) }
        var toFetch: [String] = []
        for link in linked {
            guard let key = PullRequestKey.key(link.url), keys.insert(key).inserted else { continue }
            if let known = previous?.item(forURL: link.url), !known.isOpen {
                items.append(known)
            } else {
                toFetch.append(link.url)
            }
        }
        for url in toFetch.prefix(AppModel.extraPullRequestLimit) {
            let result = await runGitHub(["pr", "view", url, "--json", fields], key: "view-\(url)")
            if result.exitCode == 0, let item = GitHubCLI.parsePullRequestInfo(result.output) {
                items.append(item)
            } else if let known = previous?.item(forURL: url) {
                // Keep what loaded before rather than dropping it.
                items.append(known)
            }
        }

        loaded.items = items
        loaded.error = problems.isEmpty ? nil : "Couldn't load " + problems.joined(separator: "; ")
        loaded.updatedAt = now()
        projectPullRequests[projectID] = loaded
        return true
    }

    /// Every project's pull requests (sidebar chips and counts).
    public func refreshAllPullRequests(force: Bool = false) async {
        await loadRemoteRepositories()
        for project in workspace.projects where tracksPullRequests(projectID: project.id) {
            await refreshPullRequests(project.id, force: force)
        }
    }

    /// Keeps review threads loaded while a view shows them: loads them now
    /// and again every refresh interval, until the calling task is
    /// cancelled (the view goes, or its pull requests change). The refresh
    /// button reloads the ones shown.
    public func watchReviewThreads(for pullRequests: [PullRequestInfo]) async {
        let keys = pullRequests.map(\.key)
        for key in keys { shownReviewThreads[key, default: 0] += 1 }
        await Polling.every(AppModel.pullRequestRefreshInterval, startNow: true) {
            await loadReviewThreads(for: pullRequests)
        }
        for key in keys {
            shownReviewThreads[key, default: 1] -= 1
            if shownReviewThreads[key] == 0 { shownReviewThreads[key] = nil }
        }
    }

    /// Unresolved review threads for open pull requests, via `gh api graphql`.
    /// A failure is remembered (the views say so) and retried next time. A
    /// pull request whose threads are already loading is skipped.
    public func loadReviewThreads(for pullRequests: [PullRequestInfo], force: Bool = false) async {
        guard gitHubCLIProblem == nil, let gh = locateGitHubCLI() else { return }
        // Go by the latest refresh, not the caller's copy: a view keeps the
        // pull requests it started with, and one may since have merged.
        let latest = pullRequests.map { pullRequest in
            projectPullRequests.values.lazy.compactMap { $0.items.first { $0.key == pullRequest.key } }.first ?? pullRequest
        }
        for pullRequest in latest where pullRequest.isOpen || reviewThreads[pullRequest.key] == nil {
            if !force, let loaded = reviewThreadsLoaded[pullRequest.key],
               now().timeIntervalSince(loaded) < AppModel.pullRequestRefreshInterval {
                continue
            }
            guard let args = GitHubCLI.reviewThreadsArguments(url: pullRequest.url),
                  loadingReviewThreads.insert(pullRequest.key).inserted else { continue }
            defer { loadingReviewThreads.remove(pullRequest.key) }
            let result = await run(GitHubCLI.command(args, in: home, gh: gh), logOnlyChanges: true, changeKey: "gh-threads|\(pullRequest.key)")
            if result.exitCode == 0, let threads = GitHubCLI.parseReviewThreads(result.output) {
                reviewThreadsLoaded[pullRequest.key] = now()
                if reviewThreads[pullRequest.key] != threads { reviewThreads[pullRequest.key] = threads }
                if reviewThreadFailures.contains(pullRequest.key) { reviewThreadFailures.remove(pullRequest.key) }
            } else if !reviewThreadFailures.contains(pullRequest.key) {
                reviewThreadFailures.insert(pullRequest.key)
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
