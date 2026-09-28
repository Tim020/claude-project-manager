import XCTest
@testable import ClaudioCore

final class ToolWindowsTests: XCTestCase {
    func testRailButtonsShowOrHide() {
        var tools = ToolWindows()
        tools.toggle(LeftTool.sessions)
        XCTAssertNil(tools.visibleLeft, "clicking the tool that's showing hides its side")
        tools.toggle(LeftTool.pullRequests)
        XCTAssertEqual(tools.visibleLeft, .pullRequests, "another tool opens the side on it")
        tools.toggle(LeftTool.sessions)
        XCTAssertEqual(tools.visibleLeft, .sessions, "switching doesn't hide")

        tools.toggle(RightTool.pullRequest)
        XCTAssertEqual(tools.visibleRight, .pullRequest)
        tools.toggle(RightTool.changes)
        XCTAssertEqual(tools.visibleRight, .changes)
        tools.toggle(RightTool.changes)
        XCTAssertNil(tools.visibleRight)
        XCTAssertEqual(tools.right, .changes, "the side remembers its tool while hidden")
        XCTAssertEqual(tools.visibleLeft, .sessions, "the sides are independent")
    }

    @MainActor private func makeModel(store: MemoryStore) throws -> (AppModel, [UUID]) {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code")
        let sessions = ["a", "b"].map { Session(projectID: project, name: $0, workingDirectory: "/code", status: .awaitingInput) }
        for session in sessions { try state.workspace.addSession(session) }
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
        return (model, sessions.map(\.id))
    }

    func testToolsAreSaved() throws {
        try MainActor.assumeIsolated {
            let store = MemoryStore()
            let (model, _) = try makeModel(store: store)
            model.toggleTool(.pullRequests)
            model.toggleTool(.pullRequest)
            XCTAssertEqual(store.state.settings.toolWindows.visibleLeft, .pullRequests, "written to the store")
            XCTAssertEqual(store.state.settings.toolWindows.visibleRight, .pullRequest)
        }
    }

    func testEachSessionHasItsOwnDiff() throws {
        try MainActor.assumeIsolated {
            let (model, ids) = try makeModel(store: MemoryStore())
            model.openDiff("a.txt", for: ids[0])
            XCTAssertEqual(model.diffPath(for: ids[0]), "a.txt")
            XCTAssertEqual(model.paneMode(for: ids[1]), .terminal, "the other session keeps its terminal")
            XCTAssertNil(model.diffPath(for: ids[1]))

            model.openDiff("b.txt", for: ids[1])
            model.closeDiff(for: ids[0])
            XCTAssertEqual(model.paneMode(for: ids[0]), .terminal)
            XCTAssertEqual(model.diffPath(for: ids[1]), "b.txt", "closing one diff leaves the other")
        }
    }

    func testStatusFilterShowsTheSessionsTool() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try makeModel(store: MemoryStore())
            model.toggleTool(.pullRequests)
            model.toggleStatusFilter(.awaitingInput)
            XCTAssertEqual(model.toolWindows.visibleLeft, .sessions, "the filtered list is shown, not hidden")

            model.toggleTool(.sessions)
            XCTAssertNil(model.toolWindows.visibleLeft)
            model.toggleStatusFilter(.awaitingInput)
            XCTAssertNil(model.statusFilter)
            XCTAssertNil(model.toolWindows.visibleLeft, "turning the filter off leaves the side as it is")
        }
    }

    func testPanelEmptyText() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try makeModel(store: MemoryStore())
            XCTAssertEqual(model.pullRequestPanelEmptyText, "Checking GitHub…", "not \"not on GitHub\" before gh is checked")
            let empty = AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            XCTAssertEqual(empty.pullRequestPanelEmptyText, "No projects yet.")
        }
    }
}

/// The left rail's Pull Requests tool, using `PullRequestModelTests`' model.
extension PullRequestModelTests {
    func testPanelListsSessionsPullRequestsMostUrgentFirst() async throws {
        let failing = PullRequestFixtures.pr(1430, checks: "[\(PullRequestFixtures.failing)]")
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427)),\(failing)]"
        runner.recent = "[\(PullRequestFixtures.pr(1427)),\(failing),\(PullRequestFixtures.pr(1422, state: "MERGED")),"
            + "\(PullRequestFixtures.pr(1400, state: "MERGED"))]"
        let old = "https://github.com/dreamteamprod/DigiScript/pull/900"
        runner.views[old] = PullRequestFixtures.pr(900, state: "CLOSED", updated: "2026-01-01T10:00:00Z")
        let links = [1427, 1422].map { "https://github.com/dreamteamprod/DigiScript/pull/\($0)" } + [old]
        let (model, project, session) = try await MainActor.run { try makeModel(runner, sessionPRs: links) }
        _ = await MainActor.run { model.addProject(path: "/elsewhere") }
        await model.refreshPullRequests(project)
        await MainActor.run {
            let groups = model.pullRequestPanel()
            XCTAssertEqual(groups.map(\.projectID), [project], "a project with nothing tracked is left out")
            XCTAssertTrue(groups[0].hasLoaded)
            XCTAssertNil(groups[0].error)
            XCTAssertEqual(groups[0].items.map(\.pullRequest.number), [1430, 1427, 1422],
                           "open ones by urgency (a failing check first), then recent merged ones; the old closed one "
                           + "and #1400, merged with no session, are left out")
            XCTAssertNil(groups[0].items[0].sessionID, "no session acted on #1430")
            XCTAssertEqual(groups[0].items[1].sessionID, session)
            XCTAssertEqual(groups[0].items[1].folder, Workspace.unfiledName)

            model.includeUnlinkedPullRequests = false
            XCTAssertEqual(model.pullRequestPanel()[0].items.map(\.pullRequest.number), [1427, 1422])
            model.setActivityWindow(days: 0)
            XCTAssertEqual(model.pullRequestPanel()[0].items.map(\.pullRequest.number), [1427, 1422, 900], "any time")
        }
    }

    func testPanelCarriesTheLoadError() async throws {
        let runner = FakeGitHub()
        runner.openExit = 1
        let links = ["https://github.com/dreamteamprod/DigiScript/pull/1427"]
        let (model, project, _) = try await MainActor.run { try makeModel(runner, sessionPRs: links) }
        await model.refreshPullRequests(project)
        await MainActor.run {
            let group = model.pullRequestPanel()[0]
            XCTAssertFalse(group.hasLoaded)
            XCTAssertNotNil(group.error, "shown in place of a \"Loading…\" that would never end")
        }
    }

    func testPanelSaysWhenNothingIsOnGitHub() async throws {
        let runner = FakeGitHub()
        runner.repoExit = 1
        let (model, project, _) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequestPanelEmptyText, "None of your projects are on GitHub.")
        }
    }
}
