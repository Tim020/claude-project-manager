import XCTest
@testable import ClaudioCore

/// Refreshing keeps what loaded when gh fails, and doesn't keep polling a
/// project that isn't on GitHub.
final class PullRequestRefreshTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_790_352_000)
    let base = "https://github.com/dreamteamprod/DigiScript/pull/"

    @MainActor func makeModel(_ runner: FakeGitHub, links: [PullRequestLink] = []) throws -> (AppModel, UUID, UUID) {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/repo")
        let session = Session(projectID: project, name: "s", workingDirectory: "/repo", pullRequests: links)
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                             locateClaude: { _ in nil }, locateGitHubCLI: { "/opt/homebrew/bin/gh" }, shell: "/bin/sh",
                             now: { [unowned self] in self.clock }, home: "/")
        return (model, project, session.id)
    }

    func later() async { await MainActor.run { clock += AppModel.pullRequestRefreshInterval } }

    func testAFailedRefreshKeepsWhatLoaded() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        runner.recent = "[\(PullRequestFixtures.pr(1422, state: "MERGED"))]"
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        let loadedAt = clock

        await later()
        runner.openExit = 1
        await model.refreshPullRequests(project)
        await MainActor.run {
            let loaded = model.pullRequests(forProject: project)
            XCTAssertEqual(loaded?.items.map(\.number), [1427, 1422], "still shown")
            XCTAssertEqual(loaded?.updatedAt, loadedAt, "\"Updated\" is the last success")
            XCTAssertEqual(loaded?.attemptedAt, clock)
            XCTAssertEqual(loaded?.error, "Couldn't refresh: HTTP 502: Bad Gateway")
            XCTAssertEqual(loaded?.hasLoaded, true)
        }

        // The recent list failing alone keeps the merged ones from before.
        await later()
        runner.openExit = 0
        runner.recentExit = 1
        await model.refreshPullRequests(project)
        await MainActor.run {
            let loaded = model.pullRequests(forProject: project)
            XCTAssertEqual(loaded?.items.map(\.number), [1427, 1422])
            XCTAssertEqual(loaded?.updatedAt, clock)
            XCTAssertEqual(loaded?.error, "Couldn't load recent pull requests: HTTP 502: Bad Gateway")
        }
    }

    func testOlderLinkedPullRequests() async throws {
        // 25 closed ones known from before, then an open one that needs gh.
        let closed = (1...25).map { PullRequestLink(base + "\($0)", .opened) }
        let openLink = PullRequestLink(base + "900", .opened)
        let runner = FakeGitHub()
        for n in 1...25 { runner.views[base + "\(n)"] = PullRequestFixtures.pr(n, state: "CLOSED") }
        runner.views[base + "900"] = PullRequestFixtures.pr(900)
        let (model, project, _) = try await MainActor.run { try makeModel(runner, links: closed + [openLink]) }

        await model.refreshPullRequests(project)
        let first = await MainActor.run { model.pullRequests(forProject: project)?.items.count }
        XCTAssertEqual(first, AppModel.extraPullRequestLimit, "the first time, the limit applies")

        await later()
        await model.refreshPullRequests(project)
        await MainActor.run {
            let numbers = Set(model.pullRequests(forProject: project)?.items.map(\.number) ?? [])
            XCTAssertTrue(numbers.isSuperset(of: Set(1...20)), "known closed ones are kept without a call")
            XCTAssertTrue(numbers.contains(21), "the limit is on fetches, so the next ones load")
        }

        // A failed fetch keeps the one known before.
        await later()
        runner.views[base + "900"] = nil
        let before = await MainActor.run { model.pullRequests(forProject: project)?.items.contains { $0.number == 900 } }
        await model.refreshPullRequests(project)
        let after = await MainActor.run { model.pullRequests(forProject: project)?.items.contains { $0.number == 900 } }
        XCTAssertEqual(before, after)
    }

    func testNotAGitHubRepositoryIsntPolled() async throws {
        let runner = FakeGitHub()
        runner.repoExit = 1
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await later()
        await model.refreshAllPullRequests()
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.isNotGitHub, true)
            XCTAssertFalse(model.tracksPullRequests(projectID: project))
        }
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["repo", "view"]) }.count, 1)
        await model.refreshPullRequests(project, force: true)
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["repo", "view"]) }.count, 2, "the refresh button still tries")
    }

    /// Only gh saying there's no GitHub repository stops polling; a failure
    /// like being offline (or a GitHub Enterprise host) is retried.
    func testOtherRepositoryLookupFailuresAreRetried() async throws {
        let runner = FakeGitHub()
        runner.repoExit = 1
        runner.repoError = "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\n"
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.isNotGitHub, false)
            XCTAssertEqual(model.pullRequests(forProject: project)?.error, "error connecting to api.github.com")
        }
        runner.repoExit = 0
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        await later()
        await model.refreshPullRequests(project)
        await MainActor.run { XCTAssertEqual(model.pullRequests(forProject: project)?.items.map(\.number), [1427]) }
        XCTAssertTrue(GitHubCLI.isNotGitHubRepository("none of the git remotes configured for this repository point to a known GitHub host. To tell gh about a new GitHub host, please use `gh auth login`"))
        XCTAssertTrue(GitHubCLI.isNotGitHubRepository("failed to run git: fatal: not a git repository (or any of the parent directories): .git"))
        XCTAssertFalse(GitHubCLI.isNotGitHubRepository("HTTP 502: Bad Gateway"))
    }

    func testReviewThreadFailuresAreRetried() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        runner.threadsExit = 1
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        let pr = try await MainActor.run { try XCTUnwrap(model.pullRequests(forProject: project)?.items.first) }
        await model.loadReviewThreads(for: [pr])
        await MainActor.run {
            XCTAssertTrue(model.reviewThreadFailures.contains(pr.key))
            XCTAssertNil(model.reviewThreads[pr.key])
        }
        runner.threadsExit = 0
        await model.loadReviewThreads(for: [pr])
        await MainActor.run {
            XCTAssertEqual(model.reviewThreads[pr.key], [], "retried at once: a failure isn't stamped as loaded")
            XCTAssertFalse(model.reviewThreadFailures.contains(pr.key))
        }
    }

    /// Threads reload while a view shows them, and with the refresh button,
    /// not for every pull request ever shown.
    func testOnlyShownReviewThreadsReload() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        let pr = try await MainActor.run { try XCTUnwrap(model.pullRequests(forProject: project)?.items.first) }
        func graphqlCalls() -> Int { runner.calls.filter { $0.contains("query=\(GitHubCLI.reviewThreadsQuery)") }.count }

        let watching = Task { await model.watchReviewThreads(for: [pr]) }
        while graphqlCalls() == 0 { await Task.yield() }
        await later()
        await model.refreshAllPullRequests()
        XCTAssertEqual(graphqlCalls(), 1, "the poll leaves threads to the views")
        await model.refreshPullRequests(project, force: true)
        XCTAssertEqual(graphqlCalls(), 2, "the refresh button reloads the shown ones")
        await MainActor.run { XCTAssertFalse(model.loadingPullRequests.contains(project)) }

        watching.cancel()
        await watching.value
        await model.refreshPullRequests(project, force: true)
        XCTAssertEqual(graphqlCalls(), 2, "no longer shown")
    }

    /// A view keeps the pull requests it started with; one merged since
    /// stops reloading all the same.
    func testAMergedPullRequestStopsReloadingWhileShown() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        let shown = try await MainActor.run { try XCTUnwrap(model.pullRequests(forProject: project)?.items.first) }
        func graphqlCalls() -> Int { runner.calls.filter { $0.contains("query=\(GitHubCLI.reviewThreadsQuery)") }.count }
        await model.loadReviewThreads(for: [shown])
        XCTAssertEqual(graphqlCalls(), 1)

        runner.open = "[]"
        runner.recent = "[\(PullRequestFixtures.pr(1427, state: "MERGED"))]"
        await later()
        await model.refreshPullRequests(project)
        await model.loadReviewThreads(for: [shown])
        XCTAssertTrue(shown.isOpen, "the view's copy")
        XCTAssertEqual(graphqlCalls(), 1, "merged now: its threads are kept, not reloaded")
    }

    func testOverlappingLoadsShareOneCall() async throws {
        let runner = FakeGitHub()
        runner.threadsDelay = 50_000_000
        let (model, _, _) = try await MainActor.run { try makeModel(runner) }
        let pr = try XCTUnwrap(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1427)))
        async let first: Void = model.loadReviewThreads(for: [pr])
        async let second: Void = model.loadReviewThreads(for: [pr])
        _ = await (first, second)
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["api", "graphql"]) }.count, 1)
    }

    func testMostUrgentFirst() {
        let ready = PullRequestInfo(number: 1, url: base + "1", title: "", state: .open, checks: [.init(name: "c", state: .passing)])
        let failing = PullRequestInfo(number: 2, url: base + "2", title: "", state: .open, checks: [.init(name: "c", state: .failing)])
        let draft = PullRequestInfo(number: 3, url: base + "3", title: "", state: .draft)
        XCTAssertEqual(PullRequestInfo.mostUrgentFirst([ready, draft, failing]).map(\.number), [2, 3, 1])
    }
}

final class PullRequestLinkPersistenceTests: XCTestCase {
    func testUnknownOverviewTabsDontFailTheState() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/repo")
        try ws.addSession(Session(projectID: p, name: "s", workingDirectory: "/repo"))
        var json = try JSONSerialization.jsonObject(with: JSONFileStore.encoder.encode(ws)) as! [String: Any]
        json["overviewTabs"] = [["id": UUID().uuidString, "overview": ["somethingNew": [:]]]]
        let decoded = try JSONFileStore.decoder.decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.projects.map(\.id), [p])
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.overviewTabs, [])
    }

    func testUnknownActionsDontFailTheState() throws {
        let json = ##"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FE","name":"x","workingDirectory":"/","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z","pullRequests":[{"reference":"#1","action":"merged"}]}"##
        let session = try JSONFileStore.decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.pullRequests, [])
        XCTAssertEqual(session.name, "x")
    }

    /// History links are taken even for a live session, or one whose hooks
    /// dated it later than its history.
    func testDiscoveryAddsLinksToLiveSessions() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = Session(projectID: p, claudeSessionID: "busy", hasConversation: true, name: "busy", workingDirectory: "/code/app",
                        status: .working, createdAt: Date(timeIntervalSince1970: 1000))
        try ws.addSession(s)
        let found = DiscoveredSession(claudeSessionID: "busy", title: "t", firstPrompt: "p", summary: "stale", model: nil,
                                      workingDirectory: "/code/app", lastActivity: Date(timeIntervalSince1970: 900),
                                      pullRequests: [PullRequestLink("https://github.com/o/r/pull/1", .opened)], status: .completed)
        _ = ws.importDiscovered([found], into: p, skipping: [s.id])
        XCTAssertEqual(ws.session(s.id)?.pullRequests, [PullRequestLink("https://github.com/o/r/pull/1", .opened)])
        XCTAssertEqual(ws.session(s.id)?.status, .working, "nothing else changes")
    }
}
