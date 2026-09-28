import XCTest
@testable import ClaudioCore

final class SessionIndicatorTests: XCTestCase {
    func testPlainSessionHasNoIndicators() {
        let session = Session(projectID: UUID(), name: "Plain", workingDirectory: "/code/repo")
        XCTAssertEqual(SessionIndicators.indicators(for: session, isOpenInTerminal: false), [])
    }

    func testOnlyTheTerminalWarning() {
        let worktree = Session(projectID: UUID(), name: "s", workingDirectory: "/code/repo/.claude/worktrees/x")
        XCTAssertEqual(SessionIndicators.indicators(for: worktree, isOpenInTerminal: false), [],
                       "the worktree is in the right rail's Pull Request tool, not on the row")
        XCTAssertEqual(SessionIndicators.indicators(for: worktree, isOpenInTerminal: true).map(\.kind), [.terminal])
    }

    func testStatusHelpIncludesWhatItNeeds() {
        var session = Session(projectID: UUID(), name: "s", workingDirectory: "/code", status: .awaitingInput)
        session.needsAction = "Allow Bash: npm test?"
        XCTAssertEqual(SessionIndicators.statusHelp(session), "Awaiting Input: Allow Bash: npm test?")
        session.status = .completed
        XCTAssertEqual(SessionIndicators.statusHelp(session), "Completed")
    }
}
