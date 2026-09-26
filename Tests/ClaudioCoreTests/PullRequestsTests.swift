import XCTest
@testable import ClaudioCore

/// `gh pr list/view --json` output in the shape gh documents for these fields.
enum PullRequestFixtures {
    static func pr(_ number: Int, title: String = "A change", state: String = "OPEN", draft: Bool = false,
                   decision: String = "", checks: String = "[]", reviews: String = "[]", requests: String = "[]",
                   updated: String = "2026-09-25T10:00:00Z", repo: String = "dreamteamprod/DigiScript") -> String {
        """
        {"number":\(number),"url":"https://github.com/\(repo)/pull/\(number)","title":"\(title)","state":"\(state)","isDraft":\(draft),
         "headRefName":"branch-\(number)","baseRefName":"dev","author":{"id":"U_1","is_bot":false,"login":"Tim020","name":"Tim"},
         "createdAt":"2026-09-24T19:00:00Z","updatedAt":"\(updated)","mergedAt":\(state == "MERGED" ? "\"2026-09-25T09:00:00Z\"" : "null"),
         "additions":417,"deletions":96,"statusCheckRollup":\(checks),"reviewDecision":"\(decision)",
         "latestReviews":\(reviews),"reviewRequests":\(requests)}
        """
    }

    static let passing = #"{"__typename":"CheckRun","name":"pytest","workflowName":"server","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-25T10:00:00Z","completedAt":"2026-09-25T10:04:12Z","detailsUrl":"https://github.com/x/y/actions/runs/1"}"#
    static let failing = #"{"__typename":"CheckRun","name":"pylint","workflowName":"server","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-25T10:00:00Z","completedAt":"2026-09-25T10:01:03Z","detailsUrl":""}"#
    static let running = #"{"__typename":"CheckRun","name":"playwright","workflowName":"e2e","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-09-25T10:00:00Z","completedAt":"0001-01-01T00:00:00Z","detailsUrl":""}"#
    static let skipped = #"{"__typename":"CheckRun","name":"deploy","workflowName":"cd","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-09-25T10:00:00Z","completedAt":"2026-09-25T10:00:00Z","detailsUrl":""}"#
    static let statusContext = #"{"__typename":"StatusContext","context":"codecov/patch","state":"PENDING","startedAt":"2026-09-25T10:00:00Z","targetUrl":"https://codecov.io"}"#
}

final class PullRequestParsingTests: XCTestCase {
    func testParsesAPullRequest() throws {
        let json = PullRequestFixtures.pr(1427, title: "Fix websocket close state", decision: "CHANGES_REQUESTED",
                                          checks: "[\(PullRequestFixtures.passing),\(PullRequestFixtures.failing),\(PullRequestFixtures.skipped)]",
                                          reviews: #"[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","submittedAt":"2026-09-25T10:00:00Z"}]"#,
                                          requests: #"[{"__typename":"User","login":"reviewer2"},{"__typename":"Team","name":"Maintainers","slug":"maintainers"}]"#)
        let pr = try XCTUnwrap(GitHubCLI.parsePullRequestInfo(json))
        XCTAssertEqual(pr.number, 1427)
        XCTAssertEqual(pr.title, "Fix websocket close state")
        XCTAssertEqual(pr.state, .open)
        XCTAssertEqual(pr.headBranch, "branch-1427")
        XCTAssertEqual(pr.baseBranch, "dev")
        XCTAssertEqual(pr.author, "Tim020")
        XCTAssertEqual(pr.additions, 417)
        XCTAssertEqual(pr.deletions, 96)
        XCTAssertNil(pr.mergedAt)
        XCTAssertEqual(pr.key, "dreamteamprod/digiscript#1427")
        XCTAssertEqual(pr.checks.map(\.name), ["server / pytest", "server / pylint", "cd / deploy"])
        XCTAssertEqual(pr.checks.map(\.state), [.passing, .failing, .skipped])
        XCTAssertEqual(pr.checks[0].duration, 252)
        XCTAssertEqual(pr.reviewDecision, .changesRequested)
        XCTAssertEqual(pr.reviews, [.init(reviewer: "reviewer1", state: .changesRequested), .init(reviewer: "reviewer2", state: .requested),
                                    .init(reviewer: "maintainers", state: .requested)])
    }

    func testStates() throws {
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1, draft: true))?.state, .draft)
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1, state: "MERGED"))?.state, .merged)
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1, state: "CLOSED"))?.state, .closed)
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1, decision: "APPROVED"))?.reviewDecision, .approved)
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1, decision: "REVIEW_REQUIRED"))?.reviewDecision, .reviewRequired)
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1))?.reviewDecision, PullRequestInfo.ReviewDecision.none)
    }

    func testParsesAListAndRunningChecks() throws {
        let list = "[\(PullRequestFixtures.pr(1, checks: "[\(PullRequestFixtures.running),\(PullRequestFixtures.statusContext)]")),\(PullRequestFixtures.pr(2))]"
        let prs = try XCTUnwrap(GitHubCLI.parsePullRequests(list))
        XCTAssertEqual(prs.map(\.number), [1, 2])
        XCTAssertEqual(prs[0].checks.map(\.state), [.running, .running])
        XCTAssertNil(prs[0].checks[0].duration, "not finished")
        XCTAssertEqual(prs[0].checks[1].name, "codecov/patch")
        XCTAssertNil(GitHubCLI.parsePullRequests("no pull requests"))
        XCTAssertEqual(GitHubCLI.parsePullRequests("[]"), [])
    }

    func testRepository() {
        XCTAssertEqual(GitHubCLI.parseRepository(#"{"nameWithOwner":"dreamteamprod/DigiScript","url":"https://github.com/dreamteamprod/DigiScript"}"#),
                       GitHubCLI.Repository(nameWithOwner: "dreamteamprod/DigiScript", url: "https://github.com/dreamteamprod/DigiScript"))
        XCTAssertNil(GitHubCLI.parseRepository(""))
    }

    func testReviewThreadsKeepOnlyUnresolved() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
          {"id":"T1","isResolved":false,"isOutdated":false,"path":"server/ws/sessions.py","line":112,"originalLine":110,
           "comments":{"nodes":[{"author":{"login":"Tim020"},"body":"write_message returns None","url":"https://github.com/x/y/pull/1#discussion_r1"}]}},
          {"id":"T2","isResolved":true,"isOutdated":false,"path":"a.py","line":1,"originalLine":1,"comments":{"nodes":[{"author":{"login":"x"},"body":"done","url":""}]}},
          {"id":"T3","isResolved":false,"isOutdated":true,"path":"client/auth.ts","line":null,"originalLine":58,
           "comments":{"nodes":[{"author":null,"body":"Reset it","url":""}]}}
        ]}}}}}
        """
        let threads = try XCTUnwrap(GitHubCLI.parseReviewThreads(json))
        XCTAssertEqual(threads.map(\.id), ["T1", "T3"])
        XCTAssertEqual(threads[0].location, "server/ws/sessions.py:112")
        XCTAssertEqual(threads[0].author, "Tim020")
        XCTAssertEqual(threads[1].location, "client/auth.ts:58", "outdated threads fall back to the original line")
        XCTAssertTrue(threads[1].isOutdated)
        XCTAssertEqual(threads[1].author, "ghost")
    }

    func testReviewThreadArguments() throws {
        let args = try XCTUnwrap(GitHubCLI.reviewThreadsArguments(url: "https://github.com/dreamteamprod/DigiScript/pull/1427"))
        XCTAssertEqual(Array(args.prefix(2)), ["api", "graphql"])
        XCTAssertTrue(args.contains("owner=dreamteamprod"))
        XCTAssertTrue(args.contains("name=DigiScript"))
        XCTAssertTrue(args.contains("number=1427"))
        XCTAssertNil(GitHubCLI.reviewThreadsArguments(url: "https://example.com"))
    }

    func testKeys() {
        XCTAssertEqual(PullRequestKey.key("https://github.com/Owner/Repo/pull/12"), "owner/repo#12")
        XCTAssertEqual(PullRequestKey.key("https://github.com/owner/repo/pull/12/files"), "owner/repo#12")
        XCTAssertNil(PullRequestKey.key("https://github.com/owner/repo/issues/12"))
    }

    func testDurations() {
        XCTAssertEqual(CheckDuration.string(48), "48s")
        XCTAssertEqual(CheckDuration.string(252), "4m 12s")
        XCTAssertEqual(CheckDuration.string(63), "1m 03s")
        XCTAssertEqual(CheckDuration.string(3900), "1h 5m")
    }
}

final class PullRequestStatusTests: XCTestCase {
    func pr(_ state: PullRequestInfo.State = .open, checks: [PullRequestInfo.CheckState] = [],
            decision: PullRequestInfo.ReviewDecision = .none) -> PullRequestInfo {
        PullRequestInfo(number: 1, url: "https://github.com/o/r/pull/1", title: "t", state: state,
                        checks: checks.enumerated().map { .init(name: "c\($0.offset)", state: $0.element) }, reviewDecision: decision)
    }

    func testCheckSummaries() {
        XCTAssertEqual(pr(checks: [.passing, .failing, .failing, .skipped]).checkText, "2 failing")
        XCTAssertEqual(pr(checks: [.passing, .failing, .failing, .skipped]).checkSummary, "1 of 3 checks passing")
        XCTAssertEqual(pr(checks: [.passing, .running]).checkText, "1 running")
        XCTAssertEqual(pr(checks: [.passing, .running]).checkSummary, "1 check running")
        XCTAssertEqual(pr(checks: [.passing, .passing, .skipped]).checkText, "2 passing")
        XCTAssertEqual(pr(checks: [.passing, .passing]).checkSummary, "All 2 checks passing")
        XCTAssertEqual(pr().checkText, "No checks")
        XCTAssertNil(pr().checkState)
    }

    func testNeedsAttention() {
        XCTAssertTrue(pr(checks: [.failing]).needsAttention)
        XCTAssertTrue(pr(decision: .changesRequested).needsAttention)
        XCTAssertFalse(pr(.draft, checks: [.failing]).needsAttention, "drafts are still being worked on")
        XCTAssertFalse(pr(.merged, checks: [.failing]).needsAttention)
        XCTAssertFalse(pr(checks: [.passing], decision: .approved).needsAttention)
    }

    func testAttention() {
        XCTAssertEqual(pr(.merged).attention, .merged)
        XCTAssertEqual(pr(.closed).attention, .closed)
        XCTAssertEqual(pr(checks: [.failing], decision: .changesRequested).attention, .failing)
        XCTAssertEqual(pr(decision: .changesRequested).attention, .changesRequested)
        XCTAssertEqual(pr(checks: [.running]).attention, .waiting)
        XCTAssertEqual(pr(.draft).attention, .waiting)
        XCTAssertEqual(pr(checks: [.passing]).attention, .ready)
        XCTAssertEqual(pr(.merged, decision: .approved).reviewLabel, "Merged")
    }
}

final class PullRequestOverviewTests: XCTestCase {
    var workspace = Workspace()
    var project = UUID()
    var folder = UUID()

    func url(_ n: Int) -> String { "https://github.com/dreamteamprod/DigiScript/pull/\(n)" }

    func item(_ n: Int, _ state: PullRequestInfo.State = .open, failing: Bool = false, updated: TimeInterval = 0) -> PullRequestInfo {
        PullRequestInfo(number: n, url: url(n), title: "PR \(n)", state: state, updatedAt: Date(timeIntervalSince1970: updated),
                        checks: failing ? [.init(name: "c", state: .failing)] : [])
    }

    @discardableResult
    func session(_ name: String, role: SessionRole, prs: [Int], in folderID: UUID? = nil, archived: Bool = false) throws -> Session {
        var session = Session(projectID: project, name: name, role: role, workingDirectory: "/repo", pullRequestURLs: prs.map(url))
        session.isArchived = archived
        try workspace.addSession(session, toFolder: folderID)
        return session
    }

    override func setUpWithError() throws {
        project = workspace.addProject(path: "/repo")
        folder = try workspace.createFolder(in: project, named: "Websocket Close State")
    }

    func testGroupsByTheFolderOfTheSessionThatWroteIt() throws {
        let review = try session("Review #1427", role: .review, prs: [1427, 1430], in: folder)
        let code = try session("websocket close state", role: .code, prs: [1427], in: folder)
        try session("pdf", role: .research, prs: [1418])
        let items = [item(1427, failing: true, updated: 3), item(1430, updated: 2), item(1418, updated: 1), item(1500, updated: 4)]

        XCTAssertEqual(PullRequestOverview.sessions(for: items[0], in: workspace, projectID: project).map(\.id), [code.id, review.id],
                       "the code session first, then its reviewer")
        let groups = PullRequestOverview.groups(items, workspace: workspace, projectID: project, filter: .all, includeUnlinked: true)
        XCTAssertEqual(groups.map(\.name), ["Websocket Close State", "Unfiled", "No Session"])
        XCTAssertEqual(groups.map { $0.pullRequests.map(\.number) }, [[1427, 1430], [1418], [1500]])

        let linkedOnly = PullRequestOverview.groups(items, workspace: workspace, projectID: project, filter: .all, includeUnlinked: false)
        XCTAssertEqual(linkedOnly.map(\.name), ["Websocket Close State", "Unfiled"])
        let attention = PullRequestOverview.groups(items, workspace: workspace, projectID: project, filter: .needsAttention, includeUnlinked: true)
        XCTAssertEqual(attention.flatMap { $0.pullRequests.map(\.number) }, [1427])
        XCTAssertEqual(PullRequestOverview.count(items, workspace: workspace, projectID: project, filter: .open, includeUnlinked: false), 3)
    }

    func testArchivedSessionsDontCount() throws {
        try session("old", role: .code, prs: [1], in: folder, archived: true)
        XCTAssertNil(PullRequestOverview.group(of: item(1), in: workspace, projectID: project))
    }

    func testFolderListsOpenFirstAndSessionKeepsItsOrder() throws {
        let code = try session("s", role: .code, prs: [3, 1, 2], in: folder)
        let known = ProjectPullRequests(items: [item(1, .merged, updated: 9), item(2, updated: 1), item(3, updated: 5)])
        XCTAssertEqual(PullRequestOverview.pullRequests(in: .folder(folder), workspace: workspace, known: known).map(\.number), [3, 2, 1])
        XCTAssertEqual(PullRequestOverview.pullRequests(of: code, known: known).map(\.number), [3, 1, 2])
        XCTAssertEqual(PullRequestOverview.pullRequests(of: code, known: nil), [])
    }
}

/// Answers gh the way a signed-in gh would, from canned output.
final class FakeGitHub: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    var repo = #"{"nameWithOwner":"dreamteamprod/DigiScript","url":"https://github.com/dreamteamprod/DigiScript"}"#
    var repoExit: Int32 = 0
    var open = "[]"
    var recent = "[]"
    var views: [String: String] = [:]
    var threads = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        let args = command.arguments
        lock.withLock { _calls.append(args) }
        guard command.executable.hasSuffix("/gh") else { return CommandResult(exitCode: 0, output: "", errorOutput: "") }
        if args.starts(with: ["auth", "status"]) {
            return CommandResult(exitCode: 0, output: "✓ Logged in to github.com account Tim020 (keyring)\n", errorOutput: "")
        }
        if args.starts(with: ["repo", "view"]) {
            return CommandResult(exitCode: repoExit, output: repoExit == 0 ? repo : "", errorOutput: repoExit == 0 ? "" : "no git remotes found\n")
        }
        if args.starts(with: ["pr", "list"]) {
            return CommandResult(exitCode: 0, output: args.contains("open") ? open : recent, errorOutput: "")
        }
        if args.starts(with: ["pr", "view"]), args.count > 2, let output = views[args[2]] {
            return CommandResult(exitCode: 0, output: output, errorOutput: "")
        }
        if args.starts(with: ["api", "graphql"]) { return CommandResult(exitCode: 0, output: threads, errorOutput: "") }
        return CommandResult(exitCode: 1, output: "", errorOutput: "not found")
    }
}

final class PullRequestModelTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_790_352_000)

    @MainActor func makeModel(_ runner: FakeGitHub, sessionPRs: [String] = [], gh: String? = "/opt/homebrew/bin/gh") throws -> (AppModel, UUID, UUID) {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/repo")
        let session = Session(projectID: project, name: "websocket close state", workingDirectory: "/repo", pullRequestURLs: sessionPRs)
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                             locateClaude: { _ in nil }, locateGitHubCLI: { gh }, shell: "/bin/sh",
                             now: { [unowned self] in self.clock }, home: "/")
        return (model, project, session.id)
    }

    func testLoadsOpenRecentAndMentionedPullRequests() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        runner.recent = "[\(PullRequestFixtures.pr(1427)),\(PullRequestFixtures.pr(1422, state: "MERGED"))]"
        let old = "https://github.com/dreamteamprod/DigiScript/pull/900"
        runner.views[old] = PullRequestFixtures.pr(900, state: "CLOSED")
        let (model, project, session) = try await MainActor.run { try makeModel(runner, sessionPRs: [old, "https://github.com/dreamteamprod/DigiScript/pull/1427"]) }

        await model.refreshPullRequests(project)
        await MainActor.run {
            let loaded = model.pullRequests(forProject: project)
            XCTAssertEqual(loaded?.repository?.nameWithOwner, "dreamteamprod/DigiScript")
            XCTAssertEqual(loaded?.items.map(\.number), [1427, 1422, 900])
            XCTAssertEqual(loaded?.updatedAt, clock)
            XCTAssertNil(loaded?.error)
            XCTAssertEqual(model.pullRequests(ofSession: session).map(\.number), [900, 1427])
            XCTAssertTrue(model.showsPullRequestsRow(projectID: project))
        }

        // Fresh: not reloaded until the interval passes, unless forced.
        let before = runner.calls.count
        await model.refreshPullRequests(project)
        XCTAssertEqual(runner.calls.count, before)
        await MainActor.run { clock += AppModel.pullRequestRefreshInterval }
        await model.refreshPullRequests(project)
        XCTAssertGreaterThan(runner.calls.count, before)
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["repo", "view"]) }.count, 1, "the repository is looked up once")
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["pr", "view"]) }.count, 1, "closed ones aren't fetched again")
    }

    func testNotAGitHubRepository() async throws {
        let runner = FakeGitHub()
        runner.repoExit = 1
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.error, "no git remotes found")
            XCTAssertFalse(runner.calls.contains { $0.starts(with: ["pr", "list"]) })
        }
    }

    func testNothingWithoutGitHubCLI() async throws {
        let runner = FakeGitHub()
        let (model, project, _) = try await MainActor.run { try makeModel(runner, gh: nil) }
        await model.refreshPullRequests(project)
        await MainActor.run { XCTAssertNil(model.pullRequests(forProject: project)) }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testOverviewClosesWhenASessionIsSelected() async throws {
        let (model, project, session) = try await MainActor.run { try makeModel(FakeGitHub()) }
        await MainActor.run {
            model.showOverview(.project(project))
            XCTAssertEqual(model.overview, .project(project))
            model.select(session)
            XCTAssertNil(model.overview)

            let folder = model.createFolder(in: project, containing: session)!
            model.showOverview(.folder(.folder(folder)))
            XCTAssertEqual(model.activeOverview, .folder(.folder(folder)))
            model.deleteFolder(folder)
            XCTAssertNil(model.activeOverview, "the folder has gone")
        }
    }

    func testReviewThreadsAreCached() async throws {
        let runner = FakeGitHub()
        runner.threads = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"isOutdated":false,"path":"a.py","line":3,"comments":{"nodes":[{"author":{"login":"r"},"body":"Fix","url":""}]}}]}}}}}"#
        let (model, _, _) = try await MainActor.run { try makeModel(runner) }
        let pr = try XCTUnwrap(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1427)))
        await model.loadReviewThreads(for: [pr])
        await model.loadReviewThreads(for: [pr])
        await MainActor.run { XCTAssertEqual(model.reviewThreads[pr.key]?.map(\.location), ["a.py:3"]) }
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["api", "graphql"]) }.count, 1)
    }
}
