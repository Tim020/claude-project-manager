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
}

/// The left rail's Pull Requests tool, using `PullRequestModelTests`' model.
extension PullRequestModelTests {
    func testPanelListsSessionsPullRequestsMostUrgentFirst() async throws {
        let failing = PullRequestFixtures.pr(1430, checks: "[\(PullRequestFixtures.failing)]")
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427)),\(failing)]"
        runner.recent = "[\(PullRequestFixtures.pr(1427)),\(failing),\(PullRequestFixtures.pr(1422, state: "MERGED"))]"
        let old = "https://github.com/dreamteamprod/DigiScript/pull/900"
        runner.views[old] = PullRequestFixtures.pr(900, state: "CLOSED", updated: "2026-01-01T10:00:00Z")
        let links = [1427, 1422].map { "https://github.com/dreamteamprod/DigiScript/pull/\($0)" } + [old]
        let (model, project, session) = try await MainActor.run { try makeModel(runner, sessionPRs: links) }
        await model.refreshPullRequests(project)
        await MainActor.run {
            let groups = model.pullRequestPanel()
            XCTAssertEqual(groups.map(\.projectID), [project])
            XCTAssertTrue(groups[0].hasLoaded)
            XCTAssertEqual(groups[0].items.map(\.pullRequest.number), [1430, 1427, 1422],
                           "open ones by urgency (a failing check first), then recent merged ones; the old closed one is left out")
            XCTAssertNil(groups[0].items[0].sessionID, "no session acted on #1430")
            XCTAssertEqual(groups[0].items[1].sessionID, session)
            XCTAssertEqual(groups[0].items[1].folder, Workspace.unfiledName)

            model.includeUnlinkedPullRequests = false
            XCTAssertEqual(model.pullRequestPanel()[0].items.map(\.pullRequest.number), [1427, 1422])
            model.setActivityWindow(days: 0)
            XCTAssertEqual(model.pullRequestPanel()[0].items.map(\.pullRequest.number), [1427, 1422, 900], "any time")
        }
    }
}
