import Foundation

// Step 6a of the Project Assistant (design 9a, backend §6): plan items and
// GitHub issues, in code. Create GitHub Issue is the only thing that writes
// to GitHub. Linked issues are read every 10 minutes while the project's
// assistant is on (and when an item is opened): their state, labels and the
// pull requests that close them. From those, and from pull requests an
// item's session opened, code suggests Mark Done; it never marks anything
// done by itself.

extension AppModel {
    /// How often linked issues are read again, while the assistant is on.
    public static let linkedIssueRefreshInterval: TimeInterval = 600
    /// Opening an item reads its issue again if it's older than this.
    public static let linkedIssueViewRefresh: TimeInterval = 60

    // MARK: - Reading

    var isGitHubCLISignedIn: Bool {
        if case .signedIn = environment.githubCLI { return true }
        return false
    }

    /// The issue numbers of a project's items that aren't done.
    func linkedIssueNumbers(inProject projectID: UUID) -> [Int] {
        Array(Set(items(inProject: projectID).filter { $0.status != .done }.compactMap { IssueNumber.parse($0.issue) })).sorted()
    }

    /// An item's issue as GitHub last had it (nil before it's been read).
    public func linkedIssue(forItem item: PlanItem, inProject projectID: UUID) -> LinkedIssue? {
        IssueNumber.parse(item.issue).flatMap { linkedIssues[projectID]?.issues[$0] }
    }

    /// Whether GitHub said an item's issue doesn't exist.
    public func isLinkedIssueMissing(_ item: PlanItem, inProject projectID: UUID) -> Bool {
        IssueNumber.parse(item.issue).map { linkedIssues[projectID]?.missing.contains($0) ?? false } ?? false
    }

    /// An item's issue's web page.
    public func issueURL(forItem item: PlanItem, inProject projectID: UUID) -> URL? {
        if let issue = linkedIssue(forItem: item, inProject: projectID) { return URL(string: issue.url) }
        guard let number = IssueNumber.parse(item.issue), let repository = repository(forProject: projectID) else { return nil }
        return URL(string: "https://github.com/\(repository)/issues/\(number)")
    }

    /// The labels on an item's issue, for picking its skills.
    public func issueLabels(forItem item: PlanItem, inProject projectID: UUID) -> [String] {
        linkedIssue(forItem: item, inProject: projectID)?.labels ?? []
    }

    /// Pull requests tied to an item: those that close its issue, then
    /// those its session opened.
    public func pullRequests(forItem item: PlanItem, inProject projectID: UUID) -> [ItemPullRequest] {
        var result = (linkedIssue(forItem: item, inProject: projectID)?.closingPullRequests ?? []).map {
            ItemPullRequest(number: $0.number, url: $0.url, stateLabel: $0.state.capitalized)
        }
        for pullRequest in sessionOpenedPullRequests(of: item, inProject: projectID)
        where !result.contains(where: { $0.number == pullRequest.number }) {
            result.append(ItemPullRequest(number: pullRequest.number, url: pullRequest.url, stateLabel: pullRequest.state.label))
        }
        return result
    }

    /// Pull requests the item's session opened, as the Pull Requests
    /// overview last loaded them.
    func sessionOpenedPullRequests(of item: PlanItem, inProject projectID: UUID) -> [PullRequestInfo] {
        guard let sessionID = item.sessionID else { return [] }
        let opened = Set(pullRequestLinks(ofSession: sessionID).filter { $0.action == .opened }.map(\.number))
        guard !opened.isEmpty else { return [] }
        return (projectPullRequests[projectID]?.items ?? []).filter { opened.contains($0.number) }
    }

    /// Whether Create GitHub Issue can be offered: gh is signed in, the
    /// project is on GitHub, the item has no issue and isn't done, and the
    /// project's plan can be saved (else the issue couldn't be linked).
    public func canCreateGitHubIssue(forItem item: PlanItem, inProject projectID: UUID) -> Bool {
        isGitHubCLISignedIn && item.issue == nil && item.status != .done && repository(forProject: projectID) != nil
            && !isAssistantDataUnreadable(projectID)
    }

    // MARK: - Mark Done

    /// Items code thinks may be done, while the project's assistant is on
    /// (Automatic or Manual): evidence you haven't said Not Yet to.
    public func markDoneSuggestions(inProject projectID: UUID) -> [MarkDoneSuggestion] {
        guard isAssistantOn(inProject: projectID) else { return [] }
        let declined = gitHubData[projectID]?.declinedMarkDone ?? [:]
        return items(inProject: projectID).compactMap { item in
            guard let evidence = MarkDone.evidence(for: item, issue: linkedIssue(forItem: item, inProject: projectID),
                                                   sessionPullRequests: sessionOpenedPullRequests(of: item, inProject: projectID)),
                  !(declined[item.id] ?? []).contains(evidence.key) else { return nil }
            return MarkDoneSuggestion(itemID: item.id, evidence: evidence)
        }
    }

    public func markDoneSuggestion(forItem itemID: UUID, inProject projectID: UUID) -> MarkDoneSuggestion? {
        markDoneSuggestions(inProject: projectID).first { $0.itemID == itemID }
    }

    public func openMarkDone(_ itemID: UUID, projectID: UUID) {
        assistantPanel = .markDone(projectID: projectID, itemID: itemID)
    }

    /// Mark Done: moves the item to Done, as moving it by hand does.
    @discardableResult
    public func markItemDone(_ itemID: UUID, projectID: UUID) -> Bool {
        guard let item = item(itemID, inProject: projectID), item.status != .done,
              setStatus(.done, ofItem: itemID, projectID: projectID) else { return false }
        if case .markDone(_, itemID) = assistantPanel { assistantPanel = .list }
        showToast("Marked \"\(item.title)\" Done")
        log.append(.info, "Marked \"\(item.title)\" done")
        return true
    }

    /// Not Yet: this evidence isn't offered again for the item; new evidence is.
    public func declineMarkDone(_ itemID: UUID, projectID: UUID) {
        guard let suggestion = markDoneSuggestion(forItem: itemID, inProject: projectID) else { return }
        var data = gitHubData[projectID] ?? GitHubData()
        data.declinedMarkDone[itemID, default: []].append(suggestion.evidence.key)
        // Items that have gone don't need remembering.
        let items = Set(items(inProject: projectID).map(\.id))
        data.declinedMarkDone = data.declinedMarkDone.filter { items.contains($0.key) }
        gitHubData[projectID] = data
        if case .markDone(_, itemID) = assistantPanel { assistantPanel = .list }
        do {
            try assistantStore.saveGitHubData(data, projectID: projectID)
        } catch {
            log.append(.error, "Couldn't save Not Yet for \(workspace.project(projectID)?.name ?? "a project")",
                       detail: AppModel.describe(error) + "\nIt holds until Claudio quits.")
        }
    }

    /// At launch: each project's `github.json`.
    func loadGitHubData() {
        for project in workspace.projects where !isAssistantDataUnreadable(project.id) {
            let data = assistantStore.loadGitHubData(projectID: project.id)
            if !data.isEmpty { gitHubData[project.id] = data }
        }
    }

    // MARK: - Linked issues

    /// Every project's linked issues, while its assistant is on (every 10
    /// minutes).
    public func refreshAllLinkedIssues() async {
        await loadRemoteRepositories()
        for project in workspace.projects where isAssistantOn(inProject: project.id) {
            // A little slack, so the timer that brought us here isn't a
            // moment too early.
            await refreshLinkedIssues(project.id, maxAge: AppModel.linkedIssueRefreshInterval - 30)
        }
    }

    /// Reads a project's linked issues in one `gh api graphql` call, unless
    /// it was asked within `maxAge` about the same issues. A failure keeps
    /// what loaded before, with why.
    public func refreshLinkedIssues(_ projectID: UUID, maxAge: TimeInterval = 0) async {
        guard isGitHubCLISignedIn, let gh = locateGitHubCLI(), let project = workspace.project(projectID),
              !refreshingLinkedIssues.contains(projectID) else { return }
        let numbers = linkedIssueNumbers(inProject: projectID)
        guard !numbers.isEmpty else {
            if linkedIssues[projectID] != nil { linkedIssues[projectID] = nil }
            return
        }
        let known = linkedIssues[projectID]
        let asked = Set(known.map { Array($0.issues.keys) + Array($0.missing) } ?? [])
        if let checked = known?.checkedAt, now().timeIntervalSince(checked) < maxAge, Set(numbers).isSubset(of: asked) { return }
        if repository(forProject: projectID) == nil { await loadRemoteRepositories() }
        guard let repository = repository(forProject: projectID),
              let arguments = GitHubCLI.linkedIssuesArguments(numbers: numbers, repository: repository) else { return }
        refreshingLinkedIssues.insert(projectID)
        defer { refreshingLinkedIssues.remove(projectID) }
        let result = await run(GitHubCLI.command(arguments, in: project.path, gh: gh), logOnlyChanges: true,
                               changeKey: "gh-linked-issues|\(project.path)")
        var updated = linkedIssues[projectID] ?? LinkedIssues()
        updated.checkedAt = now()
        // An issue that doesn't exist makes gh exit 1 with the rest answered.
        if let parsed = GitHubCLI.parseLinkedIssues(result.output, asked: numbers) {
            updated.issues = parsed.issues
            updated.missing = parsed.missing
            updated.error = nil
        } else {
            updated.error = AppModel.failureReason(result, command: "gh api graphql")
        }
        if updated != linkedIssues[projectID] { linkedIssues[projectID] = updated }
    }

    // MARK: - Create GitHub Issue

    /// Create GitHub Issue: `gh issue create` in the project's repository,
    /// titled as the item, its notes as the body. Stores "#n" on the item
    /// (with an audit entry), and logs it. The only write to GitHub.
    @discardableResult
    public func createGitHubIssue(forItem itemID: UUID, projectID: UUID) async -> Bool {
        guard let item = item(itemID, inProject: projectID), canCreateGitHubIssue(forItem: item, inProject: projectID),
              !creatingIssues.contains(itemID), let project = workspace.project(projectID),
              let repository = repository(forProject: projectID), let gh = locateGitHubCLI() else { return false }
        creatingIssues.insert(itemID)
        defer { creatingIssues.remove(itemID) }
        // The body goes in a file, so notes stay out of the command line
        // (the app's Activity Log records commands).
        let folder = assistantStore.runsDirectory() ?? FileManager.default.temporaryDirectory
        let bodyFile = folder.appendingPathComponent("issue-\(UUID().uuidString).md")
        let body = GitHubCLI.issueBody(title: item.title, notes: notes(forItem: itemID, inProject: projectID).map(\.text))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: bodyFile, options: .atomic)
        } catch {
            report("Couldn't create the GitHub issue: \(AppModel.describe(error))")
            return false
        }
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        // `--repo`, so gh never asks which remote (a fork has two).
        let arguments = GitHubCLI.createIssueArguments(title: item.title, bodyFile: bodyFile.path) + ["--repo", repository]
        let result = await run(GitHubCLI.command(arguments, in: project.path, gh: gh))
        guard result.exitCode == 0, let created = GitHubCLI.parseCreatedIssue(result.output) else {
            report("Couldn't create the GitHub issue: " + AppModel.sentence(AppModel.failureReason(result, command: "gh issue create")))
            return false
        }
        let issue = IssueNumber.format(created.number)
        // The item may have changed (or gone) while gh ran.
        guard self.item(itemID, inProject: projectID) != nil,
              updateItem(itemID, projectID: projectID, { $0.issue = issue }) else {
            report("Created GitHub issue \(issue), but couldn't save it on \"\(item.title)\": \(created.url)")
            return false
        }
        showToast("Created GitHub issue \(issue)")
        log.append(.info, "Created GitHub issue \(issue) for \"\(item.title)\"", detail: created.url)
        await refreshLinkedIssues(projectID)
        return true
    }
}
