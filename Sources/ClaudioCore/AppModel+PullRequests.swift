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
    /// The most pull requests the whole history loads (about 40 s of gh).
    static let historyPullRequestLimit = 5000
    /// How long the history's gh call may take (others get the runner's 60 s).
    static let historyTimeout: TimeInterval = 180

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

    /// When a filter's count is more than the list shows (older ones are
    /// loading, failed to load, or are past what loads): how many are
    /// listed, the count, and the repository's pull requests on GitHub.
    public func unlistedPullRequests(projectID: UUID, filter: PullRequestFilter) -> (listed: Int, total: Int, url: String)? {
        let known = projectPullRequests[projectID]
        let listed = PullRequestOverview.loadedCount(known, workspace: workspace, projectID: projectID,
                                                     filter: filter, includeUnlinked: includeUnlinkedPullRequests)
        let total = pullRequestCount(projectID: projectID, filter: filter)
        guard total > listed, let repository = known?.repository else { return nil }
        let query: String
        switch filter {
        case .needsAttention, .open: query = "is%3Apr+is%3Aopen"
        case .merged: query = "is%3Apr+is%3Amerged"
        case .all: query = "is%3Apr"
        }
        return (listed, total, repository.url + "/pulls?q=" + query)
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
        let attemptedAt = now()
        loaded.attemptedAt = attemptedAt
        // A failure (or the repository, once known) goes onto the latest
        // value, not `previous`: a history load or an older pull request's
        // details may have landed meanwhile. The success path at the end
        // writes `loaded`, taking the history from the latest value.
        func update(_ body: (inout ProjectPullRequests) -> Void) {
            var current = projectPullRequests[projectID] ?? loaded
            current.attemptedAt = attemptedAt
            body(&current)
            projectPullRequests[projectID] = current
        }
        if loaded.repository == nil {
            await loadRemoteRepositories()
            let result = await runGitHub(["repo", "view", "--json", "nameWithOwner,url"], key: "repo")
            guard let repository = GitHubCLI.parseRepository(result.output), result.exitCode == 0 else {
                update { current in
                    if result.exitCode != 0 {
                        current.error = Self.failureReason(result, command: "gh repo view")
                        // Only gh saying so means it isn't on GitHub: then
                        // stop polling it (and logging the same failure
                        // every 2 minutes). Anything else (offline, VPN not
                        // up yet) is retried after the usual interval.
                        current.isNotGitHub = GitHubCLI.isNotGitHubRepository(result.errorOutput)
                    } else {
                        current.error = "Couldn't read the repository from gh (gh repo view)."
                    }
                }
                return true
            }
            loaded.repository = repository
            loaded.isNotGitHub = false
            // Known from now on, for resolving sessions' "#123" links below.
            update { current in
                current.repository = repository
                current.isNotGitHub = false
            }
        }

        let fields = GitHubCLI.overviewFields
        let open = await runGitHub(["pr", "list", "--state", "open", "--limit", "\(AppModel.openPullRequestLimit)", "--json", fields], key: "open")
        guard open.exitCode == 0, let openItems = GitHubCLI.parsePullRequests(open.output) else {
            update { $0.error = "Couldn't refresh: " + Self.failureReason(open, command: "gh pr list") }
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
            problems.append("recent pull requests: " + Self.failureReason(recent, command: "gh pr list"))
        }

        // The lists stop at their limits, so the counts come from GitHub. A
        // failure keeps the totals from before, and says so.
        if let repository = loaded.repository?.nameWithOwner,
           let args = GitHubCLI.pullRequestTotalsArguments(repository: repository) {
            let result = await runGitHub(args, key: "totals")
            if result.exitCode == 0, let totals = GitHubCLI.parsePullRequestTotals(result.output) {
                loaded.totals = totals
            } else {
                problems.append("pull request totals: " + Self.failureReason(result, command: "gh api graphql"))
            }
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
            // (One from the history has no checks or review: fetch it.)
            if let known = previous?.item(forURL: link.url), !known.isOpen, known.hasDetails {
                items.append(known)
            } else {
                toFetch.append(link.url)
            }
        }
        for (index, url) in toFetch.enumerated() {
            if index < AppModel.extraPullRequestLimit {
                let result = await runGitHub(["pr", "view", url, "--json", fields], key: "view-\(url)")
                if result.exitCode == 0, let item = GitHubCLI.parsePullRequestInfo(result.output) {
                    items.append(item)
                    continue
                }
            }
            // Past the limit, or failed: keep what loaded before (perhaps the
            // history's copy) rather than dropping it.
            if let known = previous?.item(forURL: url) { items.append(known) }
        }

        // The rest of the history, if it's loaded: detailed ones win. It may
        // have finished loading while this ran, so it's taken from the latest.
        if let latest = projectPullRequests[projectID] { loaded.history = latest.history }
        // The refresh button retries the history after a failure: cleared
        // only now it's succeeded, as the new `updatedAt` sets off the next
        // try (`loadPullRequestHistory`).
        if force, loaded.history.error != nil {
            loaded.history.error = nil
            loaded.history.loadedAt = nil
        }
        for item in loaded.history.items where keys.insert(item.key).inserted { items.append(item) }

        loaded.items = items
        loaded.error = problems.isEmpty ? nil : "Couldn't load " + problems.joined(separator: "; ")
        loaded.updatedAt = now()
        projectPullRequests[projectID] = loaded
        return true
    }

    /// Loads every pull request, without details (`GitHubCLI.historyFields`),
    /// for Merged and All (with pull requests without a session included)
    /// when merged or closed ones are missing. When it loads again is
    /// `ProjectPullRequests.needsHistory`. A failure keeps what loaded
    /// before, with the error, until the refresh button retries.
    public func loadPullRequestHistory(_ projectID: UUID) async {
        guard gitHubCLIProblem == nil, let gh = locateGitHubCLI(), let project = workspace.project(projectID),
              let known = projectPullRequests[projectID], known.hasLoaded, includeUnlinkedPullRequests,
              pullRequestFilter == .merged || pullRequestFilter == .all,
              known.needsHistory(now: now(), interval: AppModel.pullRequestRefreshInterval),
              !loadingPullRequestHistory.contains(projectID) else { return }
        loadingPullRequestHistory.insert(projectID)
        defer { loadingPullRequestHistory.remove(projectID) }
        // A little over the total, for ones opened meanwhile.
        let limit = min((known.totals?.all ?? historyLimit) + 50, historyLimit)
        var command = GitHubCLI.command(["pr", "list", "--state", "all", "--limit", "\(limit)", "--json", GitHubCLI.historyFields],
                                        in: project.path, gh: gh)
        command.timeout = AppModel.historyTimeout
        // Log (and keep) a count, not up to megabytes of JSON; only the
        // code below parses it.
        let result = await run(command, logOnlyChanges: true, changeKey: "gh-history|\(project.path)",
                               loggedOutput: Self.historySummary)
        // Another load may have finished meanwhile: build on the latest.
        guard var loaded = projectPullRequests[projectID] else { return }
        loaded.history.loadedAt = now()
        guard result.exitCode == 0, let history = GitHubCLI.parsePullRequestHistory(result.output) else {
            loaded.history.error = Self.failureReason(result, command: "gh pr list")
            projectPullRequests[projectID] = loaded
            return
        }
        // Rows that came from the old history give way to the new one; the
        // lists' own (detailed) rows stay.
        let old = Dictionary(loaded.history.items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        loaded.items.removeAll { old[$0.key] == $0 }
        // Details loaded since (hover or click) stay while they're current.
        let detailed = old.filter { $0.value.hasDetails }
        loaded.history.items = history
            // Open ones come from the open list, with details; the history's
            // could be out of date by the next refresh.
            .filter { !$0.isOpen }
            .map { item in detailed[item.key].flatMap { $0.updatedAt == item.updatedAt ? $0 : nil } ?? item }
        loaded.history.totals = known.totals
        loaded.history.isCapped = history.count >= limit && limit == historyLimit
        loaded.history.error = nil
        var keys = Set(loaded.items.map(\.key))
        for item in loaded.history.items where keys.insert(item.key).inserted { loaded.items.append(item) }
        projectPullRequests[projectID] = loaded
    }

    /// What the Activity Log keeps of the history's output: how many pull
    /// requests (counted, not parsed), or the start of output that isn't a
    /// list of them.
    static func historySummary(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a whole array is counted: truncated JSON, or JSON with stray
        // text after it, is logged as it is.
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return String(trimmed.prefix(500)) }
        return "\(trimmed.components(separatedBy: "\"number\":").count - 1) pull requests"
    }

    /// Why a gh call failed, in a few words: "timed out" when the runner
    /// killed it (SIGTERM, nothing on stderr); "couldn't read <command>'s
    /// output" when it exited 0 with output that didn't parse; else gh's
    /// first line on stderr, or "<command> failed" with none.
    static func failureReason(_ result: CommandResult, command: String) -> String {
        if result.exitCode == 15 && result.errorOutput.isEmpty { return "timed out" }
        if result.exitCode == 0 { return "couldn't read \(command)'s output" }
        return firstLine(result.errorOutput) ?? "\(command) failed"
    }

    /// Loads an older pull request's checks, review and line counts (the
    /// history has none), when its row is hovered or clicked. A failure is
    /// remembered, with why: hovering doesn't retry it, clicking (`force`)
    /// does.
    public func loadPullRequestDetails(_ pullRequest: PullRequestInfo, projectID: UUID, force: Bool = false) async {
        // The model's copy, not the caller's: a click may have loaded it
        // while a hover waited.
        let current = projectPullRequests[projectID]?.item(forURL: pullRequest.url) ?? pullRequest
        guard !current.hasDetails, gitHubCLIProblem == nil, let gh = locateGitHubCLI(),
              let project = workspace.project(projectID),
              force || pullRequestDetailFailures[pullRequest.key] == nil,
              !loadingPullRequestDetails.contains(pullRequest.key) else { return }
        loadingPullRequestDetails.insert(pullRequest.key)
        defer { loadingPullRequestDetails.remove(pullRequest.key) }
        let result = await run(GitHubCLI.command(["pr", "view", pullRequest.url, "--json", GitHubCLI.overviewFields], in: project.path, gh: gh),
                               logOnlyChanges: true, changeKey: "gh-view-\(pullRequest.url)")
        guard result.exitCode == 0, let item = GitHubCLI.parsePullRequestInfo(result.output) else {
            pullRequestDetailFailures[pullRequest.key] = Self.failureReason(result, command: "gh pr view")
            return
        }
        if pullRequestDetailFailures[item.key] != nil { pullRequestDetailFailures[item.key] = nil }
        projectPullRequests[projectID]?.replace(item)
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
