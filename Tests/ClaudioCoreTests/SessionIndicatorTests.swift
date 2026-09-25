import XCTest
@testable import ClaudioCore

final class SessionIndicatorTests: XCTestCase {
    func testPlainSessionHasNoIndicators() {
        let session = Session(projectID: UUID(), name: "Plain", workingDirectory: "/code/repo")
        XCTAssertEqual(SessionIndicators.indicators(for: session, isOpenInTerminal: false), [])
    }

    func testWorktreeIndicatorNamesTheWorktree() throws {
        let session = Session(projectID: UUID(), name: "Test", workingDirectory: "/code/repo/.claude/worktrees/test")
        let indicator = try XCTUnwrap(SessionIndicators.indicators(for: session, isOpenInTerminal: false).first)
        XCTAssertEqual(indicator.kind, .worktree)
        XCTAssertTrue(indicator.help.contains("“test”"))
        XCTAssertTrue(indicator.help.contains(".claude/worktrees/test"))
    }

    func testIndicatorsInOrderWithPullRequestCount() {
        var session = Session(projectID: UUID(), name: "s", workingDirectory: "/code/repo/.claude/worktrees/x")
        session.pullRequestURLs = ["https://github.com/o/r/pull/1427", "https://github.com/o/r/pull/1430"]
        let indicators = SessionIndicators.indicators(for: session, isOpenInTerminal: true)
        XCTAssertEqual(indicators.map(\.kind), [.terminal, .worktree, .pullRequests])
        XCTAssertEqual(indicators.last?.text, "2")
        XCTAssertEqual(indicators.last?.help, "2 pull requests: #1427, #1430")
    }

    func testSinglePullRequest() {
        XCTAssertEqual(SessionIndicators.pullRequestHelp(["https://github.com/o/r/pull/7"]), "1 pull request: #7")
    }

    func testStatusHelpIncludesWhatItNeeds() {
        var session = Session(projectID: UUID(), name: "s", workingDirectory: "/code", status: .awaitingInput)
        session.needsAction = "Allow Bash: npm test?"
        XCTAssertEqual(SessionIndicators.statusHelp(session), "Awaiting Input: Allow Bash: npm test?")
        session.status = .completed
        XCTAssertEqual(SessionIndicators.statusHelp(session), "Completed")
    }
}
