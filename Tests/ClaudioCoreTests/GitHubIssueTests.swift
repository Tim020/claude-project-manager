import XCTest
@testable import ClaudioCore

/// Answers gh with recorded output: signed in, `gh issue create`, and the
/// linked-issues query. git answers `remote get-url origin`. Records gh's
/// arguments, and the issue body file's text when it's created.
final class FakeGitHubIssues: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _bodies: [String] = []
    var remote = "git@github.com:Tim020/claude-project-manager.git\n"
    var createResult = CommandResult(exitCode: 0, output: "https://github.com/Tim020/claude-project-manager/issues/50\n", errorOutput: "")
    var linkedResult = CommandResult(exitCode: 0, output: "", errorOutput: "")

    var calls: [[String]] { lock.withLock { _calls } }
    var bodies: [String] { lock.withLock { _bodies } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        if command.executable.hasSuffix("/git") { return CommandResult(exitCode: 0, output: remote, errorOutput: "") }
        guard command.executable.hasSuffix("/gh") else { return CommandResult(exitCode: 0, output: "", errorOutput: "") }
        let args = command.arguments
        lock.withLock { _calls.append(args) }
        if args.starts(with: ["auth", "status"]) {
            return CommandResult(exitCode: 0, output: "github.com\n  ✓ Logged in to github.com account Tim020 (keyring)\n", errorOutput: "")
        }
        if args.starts(with: ["issue", "create"]) {
            if let index = args.firstIndex(of: "--body-file"), index + 1 < args.count,
               let body = try? String(contentsOfFile: args[index + 1], encoding: .utf8) {
                lock.withLock { _bodies.append(body) }
            }
            return lock.withLock { createResult }
        }
        if args.starts(with: ["api", "graphql"]) { return lock.withLock { linkedResult } }
        return CommandResult(exitCode: 1, output: "", errorOutput: "unexpected")
    }
}

/// Step 6a: plan items and GitHub issues. Create GitHub Issue, linked
/// issues, Mark Done, and issue labels in chip scoring.
final class GitHubIssueTests: XCTestCase {
    static let now = ISO8601DateFormatter().date(from: "2026-10-15T21:00:00Z")!

    // MARK: - Parsing recorded output

    func testCreatedIssueIsReadFromItsURL() throws {
        let created = GitHubCLI.parseCreatedIssue(try Fixtures.string("gh-issue-create.txt"))
        XCTAssertEqual(created?.number, 50)
        XCTAssertEqual(created?.url, "https://github.com/Tim020/claude-project-manager/issues/50")
        XCTAssertNil(GitHubCLI.parseCreatedIssue("Creating issue in Tim020/claude-project-manager\n"))
        XCTAssertEqual(GitHubCLI.parseCreatedIssue("\nCreating issue…\n\nhttps://github.com/a/b/issues/7\n")?.number, 7)
    }

    func testIssueNumbers() {
        XCTAssertEqual(IssueNumber.parse("#23"), 23)
        XCTAssertEqual(IssueNumber.parse(" #23 "), 23)
        XCTAssertNil(IssueNumber.parse("23"))
        XCTAssertNil(IssueNumber.parse("#0"))
        XCTAssertNil(IssueNumber.parse("#x"))
        XCTAssertNil(IssueNumber.parse(nil))
        XCTAssertEqual(IssueNumber.format(50), "#50")
    }

    func testIssueBodyIsTheNotesOrTheTitle() {
        XCTAssertEqual(GitHubCLI.issueBody(title: "T", notes: ["First", "  ", "Second\nline"]), "First\n\nSecond\nline\n")
        XCTAssertEqual(GitHubCLI.issueBody(title: "Just a title", notes: []), "Just a title\n")
    }

    func testCreateArgumentsKeepTheBodyOutOfTheCommandLine() {
        XCTAssertEqual(GitHubCLI.createIssueArguments(title: "- starts with a dash", bodyFile: "/tmp/b.md"),
                       ["issue", "create", "--title", "- starts with a dash", "--body-file", "/tmp/b.md"])
    }

    func testLinkedIssuesQuery() throws {
        let args = try XCTUnwrap(GitHubCLI.linkedIssuesArguments(numbers: [889, 1164], repository: "dreamteamprod/DigiScript"))
        XCTAssertEqual(Array(args.prefix(3)), ["api", "graphql", "-f"])
        XCTAssertTrue(args[3].contains("i889: issue(number: 889) { ...F } i1164: issue(number: 1164) { ...F }"))
        XCTAssertTrue(args[3].contains("closedByPullRequestsReferences(first: 5, includeClosedPrs: true)"))
        XCTAssertEqual(Array(args.suffix(4)), ["-F", "owner=dreamteamprod", "-F", "name=DigiScript"])
        XCTAssertNil(GitHubCLI.linkedIssuesArguments(numbers: [], repository: "a/b"))
        XCTAssertNil(GitHubCLI.linkedIssuesArguments(numbers: [1], repository: "not-a-repository"))
        let many = try XCTUnwrap(GitHubCLI.linkedIssuesArguments(numbers: Array(1...80), repository: "a/b"))
        XCTAssertTrue(many[3].contains("i50:"))
        XCTAssertFalse(many[3].contains("i51:"), "at most \(GitHubCLI.linkedIssueLimit) in one query")
    }

    func testLinkedIssuesFromRecordedOutput() throws {
        // DigiScript, gh 2.101.0: open with an open PR, closed by a merged PR,
        // closed as not planned, and one that doesn't exist (gh exited 1).
        let parsed = try XCTUnwrap(GitHubCLI.parseLinkedIssues(try Fixtures.string("gh-linked-issues.json"),
                                                              asked: [889, 1164, 1424, 999_999]))
        XCTAssertEqual(parsed.missing, [999_999])
        let open = try XCTUnwrap(parsed.issues[889])
        XCTAssertTrue(open.isOpen)
        XCTAssertEqual(open.labels, ["client", "server"])
        XCTAssertEqual(open.closingPullRequests.map(\.number), [905])
        XCTAssertFalse(open.closingPullRequests[0].isMerged)
        let fixed = try XCTUnwrap(parsed.issues[1164])
        XCTAssertEqual(fixed.state, .closed(reason: "COMPLETED"))
        XCTAssertNotNil(fixed.closedAt)
        XCTAssertEqual(fixed.closingPullRequests.first?.isMerged, true)
        XCTAssertEqual(fixed.closingPullRequests.first?.baseBranch, "dev")
        XCTAssertEqual(fixed.closingPullRequests.first?.mergeCommit, "f123b1795e4afd9bedcc5389eb2a606dc21c4165")
        XCTAssertEqual(parsed.issues[1424]?.state, .closed(reason: "NOT_PLANNED"))

        // This repository: a pull request's number isn't an issue.
        let own = try XCTUnwrap(GitHubCLI.parseLinkedIssues(try Fixtures.string("gh-linked-issues-pr-number.json"), asked: [50, 47, 1]))
        XCTAssertEqual(own.missing, [47])
        XCTAssertEqual(own.issues[50]?.state, .closed(reason: "COMPLETED"))
        XCTAssertEqual(own.issues[1]?.labels, ["enhancement"])

        XCTAssertNil(GitHubCLI.parseLinkedIssues("", asked: [1]))
        XCTAssertNil(GitHubCLI.parseLinkedIssues("gh: HTTP 502", asked: [1]))
    }

    // MARK: - Mark Done evidence

    func testMarkDoneEvidence() {
        let merged = Date(timeIntervalSince1970: 1_000)
        let item = PlanItem(title: "Fix it", status: .inSession, issue: "#19", createdAt: Self.now)
        let closedByPR = LinkedIssue(number: 19, url: "u", state: .closed(reason: "COMPLETED"), closingPullRequests: [
            ClosingPullRequest(number: 13, url: "p13", state: "CLOSED"),
            ClosingPullRequest(number: 14, url: "p14", state: "MERGED", mergedAt: merged, baseBranch: "main", mergeCommit: "352ddc7abc"),
        ])
        let evidence = MarkDone.evidence(for: item, issue: closedByPR, sessionPullRequests: [])
        XCTAssertEqual(evidence?.key, "pr#14:merged", "a merged PR that closes it is the strongest")
        XCTAssertEqual(evidence?.sentence, "PR #14 was merged into main as 352ddc7, closing issue #19.")
        XCTAssertEqual(evidence?.date, merged)

        let closed = LinkedIssue(number: 19, url: "u", state: .closed(reason: "NOT_PLANNED"))
        XCTAssertEqual(MarkDone.evidence(for: item, issue: closed, sessionPullRequests: [])?.sentence,
                       "Issue #19 was closed as not planned.")
        XCTAssertEqual(MarkDone.evidence(for: item, issue: LinkedIssue(number: 19, url: "u", state: .closed(reason: "COMPLETED")),
                                         sessionPullRequests: [])?.sentence, "Issue #19 was closed.")

        let open = LinkedIssue(number: 19, url: "u", state: .open)
        XCTAssertNil(MarkDone.evidence(for: item, issue: open, sessionPullRequests: []))
        let sessionPR = PullRequestInfo(number: 30, url: "p30", title: "", state: .merged, baseBranch: "dev", mergedAt: merged)
        XCTAssertEqual(MarkDone.evidence(for: item, issue: open, sessionPullRequests: [sessionPR])?.sentence,
                       "PR #30 was merged into dev.", "a PR its session opened")
        let idea = PlanItem(title: "Idea", status: .idea, createdAt: Self.now)
        XCTAssertNil(MarkDone.evidence(for: idea, issue: nil, sessionPullRequests: [sessionPR]),
                     "only an item a session is working on")
        var done = item
        done.status = .done
        XCTAssertNil(MarkDone.evidence(for: done, issue: closedByPR, sessionPullRequests: []))
    }

    func testGitHubDataReadsTolerantly() throws {
        let id = UUID()
        let data = GitHubData(declinedMarkDone: [id: ["issue#3:closed"]])
        let decoded = try JSONFileStore.decoder.decode(GitHubData.self, from: JSONFileStore.encoder.encode(data))
        XCTAssertEqual(decoded, data)
        let odd = #"{"declinedMarkDone": {"not-a-uuid": ["x"], "\#(id.uuidString)": ["pr#1:merged"]}, "later": 2}"#
        XCTAssertEqual(try JSONFileStore.decoder.decode(GitHubData.self, from: Data(odd.utf8)).declinedMarkDone, [id: ["pr#1:merged"]])
        XCTAssertEqual(try JSONFileStore.decoder.decode(GitHubData.self, from: Data(#"{"declinedMarkDone": 3}"#.utf8)), GitHubData())
    }

    // MARK: - In the model

    struct Fixture {
        let model: AppModel
        let runner: FakeGitHubIssues
        let assistant: MemoryAssistantStore
        let project: UUID
        let item: UUID
    }

    /// A project at `/code/app` on GitHub, with one Planned item and a note
    /// attached to it, and gh signed in.
    @MainActor func makeFixture(issue: String? = nil, status: PlanStatus = .planned, signIn: Bool = true,
                                runner: FakeGitHubIssues = FakeGitHubIssues()) async throws -> Fixture {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let store = MemoryStore()
        store.state = state
        let assistant = MemoryAssistantStore()
        let item = PlanItem(title: "Remember the shell panel height", status: status, issue: issue, createdAt: Self.now)
        var data = AssistantData()
        data.items = [item]
        data.notes = [ProjectNote(text: "Per project, please.", author: .user, createdAt: Self.now, itemID: item.id)]
        assistant.data[project] = data
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                             assistantStore: assistant, locateClaude: { _ in nil }, locateGitHubCLI: { "/opt/homebrew/bin/gh" },
                             shell: "/bin/sh", now: { Self.now }, home: "/")
        if signIn { await model.checkEnvironment(force: true) }
        await model.loadRemoteRepositories()
        return Fixture(model: model, runner: runner, assistant: assistant, project: project, item: item.id)
    }

    func testCreateGitHubIssueLinksTheItem() async throws {
        let f = try await makeFixture()
        let offered = await MainActor.run { () -> Bool in
            guard let item = f.model.item(f.item, inProject: f.project) else { return false }
            return f.model.canCreateGitHubIssue(forItem: item, inProject: f.project)
        }
        XCTAssertTrue(offered)
        let created = await f.model.createGitHubIssue(forItem: f.item, projectID: f.project)
        XCTAssertTrue(created)
        let call = try XCTUnwrap(f.runner.calls.first { $0.starts(with: ["issue", "create"]) })
        XCTAssertEqual(Array(call.prefix(4)), ["issue", "create", "--title", "Remember the shell panel height"])
        XCTAssertEqual(Array(call.suffix(2)), ["--repo", "Tim020/claude-project-manager"])
        XCTAssertEqual(f.runner.bodies, ["Per project, please.\n"], "the notes are the body, from a file")
        await MainActor.run {
            XCTAssertEqual(f.model.item(f.item, inProject: f.project)?.issue, "#50")
            XCTAssertEqual(f.assistant.data[f.project]?.items.first?.issue, "#50", "saved")
            let audit = f.assistant.audit[f.project] ?? []
            XCTAssertEqual(audit.last?.action, .itemChanged)
            XCTAssertEqual(audit.last?.afterItem?.issue, "#50")
            XCTAssertEqual(f.model.toast?.text, "Created GitHub issue #50")
            XCTAssertFalse(f.model.log.entries.contains { $0.title.contains("Per project") || ($0.detail ?? "").contains("Per project") },
                           "the notes stay out of the app's log")
            XCTAssertTrue(f.model.creatingIssues.isEmpty)
            let item = f.model.item(f.item, inProject: f.project)!
            XCTAssertFalse(f.model.canCreateGitHubIssue(forItem: item, inProject: f.project), "it has one now")
        }
        // The body file is gone.
        let call2 = f.runner.calls.first { $0.starts(with: ["issue", "create"]) }!
        let path = call2[call2.firstIndex(of: "--body-file")! + 1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(f.runner.calls.contains { $0.starts(with: ["api", "graphql"]) }, "and its state is read")
    }

    func testCreateGitHubIssueFailingChangesNothing() async throws {
        let runner = FakeGitHubIssues()
        runner.createResult = CommandResult(exitCode: 1, output: "", errorOutput: "HTTP 410: Issues are disabled for this repo\n")
        let f = try await makeFixture(runner: runner)
        let created = await f.model.createGitHubIssue(forItem: f.item, projectID: f.project)
        XCTAssertFalse(created)
        await MainActor.run {
            XCTAssertNil(f.model.item(f.item, inProject: f.project)?.issue)
            XCTAssertEqual(f.model.errorMessage, "Couldn't create the GitHub issue: HTTP 410: Issues are disabled for this repo.")
        }
    }

    func testNoCreateWithoutGitHub() async throws {
        let signedOut = try await makeFixture(signIn: false)
        await MainActor.run {
            let item = signedOut.model.item(signedOut.item, inProject: signedOut.project)!
            XCTAssertFalse(signedOut.model.canCreateGitHubIssue(forItem: item, inProject: signedOut.project), "gh not signed in")
        }
        let runner = FakeGitHubIssues()
        runner.remote = "git@gitlab.com:me/app.git\n"
        let notGitHub = try await makeFixture(runner: runner)
        let created = await notGitHub.model.createGitHubIssue(forItem: notGitHub.item, projectID: notGitHub.project)
        XCTAssertFalse(created, "not a GitHub repository")
        XCTAssertFalse(runner.calls.contains { $0.starts(with: ["issue", "create"]) })
        let done = try await makeFixture(status: .done)
        await MainActor.run {
            let item = done.model.item(done.item, inProject: done.project)!
            XCTAssertFalse(done.model.canCreateGitHubIssue(forItem: item, inProject: done.project), "done items aren't exported")
        }
    }

    func testMarkDoneFromALinkedIssue() async throws {
        let runner = FakeGitHubIssues()
        runner.linkedResult = CommandResult(exitCode: 0, output: try Fixtures.string("gh-linked-issues-pr-number.json"), errorOutput: "")
        let f = try await makeFixture(issue: "#50", status: .inSession, runner: runner)
        await f.model.refreshLinkedIssues(f.project)
        await MainActor.run {
            let item = f.model.item(f.item, inProject: f.project)!
            XCTAssertEqual(f.model.linkedIssue(forItem: item, inProject: f.project)?.state, .closed(reason: "COMPLETED"))
            let suggestions = f.model.markDoneSuggestions(inProject: f.project)
            XCTAssertEqual(suggestions.map(\.itemID), [f.item])
            XCTAssertEqual(suggestions.first?.evidence.sentence, "Issue #50 was closed.")
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1)
            XCTAssertEqual(f.model.issueURL(forItem: item, inProject: f.project)?.absoluteString,
                           "https://github.com/Tim020/claude-project-manager/issues/50")

            // Off: no suggestion (Manual still has one).
            f.model.setAssistantMode(.off, projectID: f.project)
            XCTAssertTrue(f.model.markDoneSuggestions(inProject: f.project).isEmpty)
            f.model.setAssistantMode(.manual, projectID: f.project)
            XCTAssertEqual(f.model.markDoneSuggestions(inProject: f.project).count, 1)

            XCTAssertTrue(f.model.markItemDone(f.item, projectID: f.project))
            XCTAssertEqual(f.model.item(f.item, inProject: f.project)?.status, .done)
            XCTAssertTrue(f.model.markDoneSuggestions(inProject: f.project).isEmpty, "done: nothing to suggest")
            XCTAssertEqual(f.assistant.audit[f.project]?.last?.afterItem?.status, .done, "recorded like a move by hand")
        }
    }

    func testNotYetHoldsUntilThereIsNewEvidence() async throws {
        let runner = FakeGitHubIssues()
        runner.linkedResult = CommandResult(exitCode: 0, output: try Fixtures.string("gh-linked-issues-pr-number.json"), errorOutput: "")
        let f = try await makeFixture(issue: "#50", status: .inSession, runner: runner)
        await f.model.refreshLinkedIssues(f.project)
        await MainActor.run {
            f.model.openMarkDone(f.item, projectID: f.project)
            f.model.declineMarkDone(f.item, projectID: f.project)
            XCTAssertTrue(f.model.markDoneSuggestions(inProject: f.project).isEmpty)
            XCTAssertEqual(f.model.assistantPanel, .list, "the view closes")
            XCTAssertEqual(f.assistant.gitHub[f.project]?.declinedMarkDone[f.item], ["issue#50:closed"], "saved")
        }
        // A merged PR that closes it is new evidence.
        let merged = """
            {"data":{"repository":{"i50":{"number":50,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-10-15T20:57:08Z",\
            "url":"https://github.com/Tim020/claude-project-manager/issues/50","labels":{"nodes":[]},\
            "closedByPullRequestsReferences":{"nodes":[{"number":51,"state":"MERGED","mergedAt":"2026-10-15T20:57:00Z",\
            "url":"https://github.com/Tim020/claude-project-manager/pull/51","baseRefName":"main","mergeCommit":{"oid":"abcdef1234"}}]}}}}}
            """
        runner.linkedResult = CommandResult(exitCode: 0, output: merged, errorOutput: "")
        await f.model.refreshLinkedIssues(f.project)
        await MainActor.run {
            XCTAssertEqual(f.model.markDoneSuggestions(inProject: f.project).first?.evidence.sentence,
                           "PR #51 was merged into main as abcdef1, closing issue #50.")
            let item = f.model.item(f.item, inProject: f.project)!
            XCTAssertEqual(f.model.pullRequests(forItem: item, inProject: f.project).map(\.number), [51])
        }

        // Not Yet survives a relaunch.
        let hookLog = try makeTemporaryDirectory().appendingPathComponent("h.log")
        let relaunched = await MainActor.run { () -> AppModel in
            f.model.declineMarkDone(f.item, projectID: f.project)
            let store = MemoryStore()
            store.state = f.model.state
            return AppModel(store: store, discovery: f.model.discovery, hookEventsURL: hookLog, runner: runner,
                            assistantStore: f.assistant, locateClaude: { _ in nil }, locateGitHubCLI: { "/opt/homebrew/bin/gh" },
                            shell: "/bin/sh", now: { Self.now }, home: "/")
        }
        await relaunched.checkEnvironment(force: true)
        await relaunched.loadRemoteRepositories()
        await relaunched.refreshLinkedIssues(f.project)
        await MainActor.run {
            XCTAssertNotNil(relaunched.linkedIssues[f.project]?.issues[50])
            XCTAssertTrue(relaunched.markDoneSuggestions(inProject: f.project).isEmpty)
        }
    }

    func testRefreshingLinkedIssues() async throws {
        let runner = FakeGitHubIssues()
        runner.linkedResult = CommandResult(exitCode: 1, output: try Fixtures.string("gh-linked-issues-pr-number.json"),
                                            errorOutput: "gh: Could not resolve to an Issue with the number of 47.\n")
        let f = try await makeFixture(issue: "#47", runner: runner)
        await f.model.refreshLinkedIssues(f.project)
        await MainActor.run {
            let item = f.model.item(f.item, inProject: f.project)!
            XCTAssertTrue(f.model.isLinkedIssueMissing(item, inProject: f.project), "read despite exit 1")
            XCTAssertNil(f.model.linkedIssues[f.project]?.error)
        }
        // Fresh: asked again only after maxAge, or for a new issue.
        let before = f.runner.calls.count
        await f.model.refreshLinkedIssues(f.project, maxAge: 60)
        XCTAssertEqual(f.runner.calls.count, before)

        // A failure keeps what loaded, with why.
        runner.linkedResult = CommandResult(exitCode: 1, output: "", errorOutput: "HTTP 502: Bad Gateway\n")
        await f.model.refreshLinkedIssues(f.project)
        await MainActor.run {
            XCTAssertEqual(f.model.linkedIssues[f.project]?.missing, [47])
            XCTAssertEqual(f.model.linkedIssues[f.project]?.error, "HTTP 502: Bad Gateway")
        }

        // Only items that aren't done are asked about.
        await MainActor.run { _ = f.model.setStatus(.done, ofItem: f.item, projectID: f.project) }
        await f.model.refreshLinkedIssues(f.project)
        await MainActor.run { XCTAssertNil(f.model.linkedIssues[f.project], "nothing to ask about") }
    }

    func testAllLinkedIssuesOnlyWhileTheAssistantIsOn() async throws {
        let runner = FakeGitHubIssues()
        runner.linkedResult = CommandResult(exitCode: 0, output: try Fixtures.string("gh-linked-issues-pr-number.json"), errorOutput: "")
        let f = try await makeFixture(issue: "#50", runner: runner)
        await MainActor.run { f.model.setAssistantMode(.off, projectID: f.project) }
        await f.model.refreshAllLinkedIssues()
        XCTAssertFalse(runner.calls.contains { $0.starts(with: ["api", "graphql"]) })
        await MainActor.run { f.model.setAssistantMode(.automatic, projectID: f.project) }
        await f.model.refreshAllLinkedIssues()
        XCTAssertTrue(runner.calls.contains { $0.starts(with: ["api", "graphql"]) })
    }

    func testIssueLabelsHelpPickSkills() {
        let ui = ApprovedSkill(name: "ui-style", tags: ["Enhancement"])
        let other = ApprovedSkill(name: "other", tags: ["Backend"])
        XCTAssertEqual(SkillChips.pick(from: [ui, other], touchedFiles: [], folderNames: [], issueLabels: ["enhancement"]).map(\.name),
                       ["ui-style"], "a label that's also one of the skill's tags, without regard to case")
        XCTAssertTrue(SkillChips.pick(from: [ui, other], touchedFiles: [], folderNames: [], issueLabels: ["bug"]).isEmpty)
    }
}
