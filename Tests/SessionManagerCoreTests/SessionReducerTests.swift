import XCTest
@testable import SessionManagerCore

final class SessionReducerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_000)

    private func makeSession() -> Session {
        Session(projectID: UUID(), name: "investigate issue correlation", workingDirectory: "/code", status: .completed,
                createdAt: Date(timeIntervalSince1970: 0))
    }

    func testSendingPromptMarksWorking() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.promptSent(to: &session, activity: &state, now: now)
        XCTAssertEqual(session.status, .working)
        XCTAssertTrue(state.isTurnActive)
        XCTAssertEqual(session.lastActivity, now)
        XCTAssertNil(session.needsAction)
    }

    func testInitRecordsClaudeSessionAndModel() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.apply(.initialized(sessionID: "abc", model: "claude-opus-5-5", cwd: "/code"), to: &session, activity: &state, now: now)
        XCTAssertEqual(session.claudeSessionID, "abc")
        XCTAssertEqual(session.model, "claude-opus-5-5")
        XCTAssertTrue(session.hasConversation)
    }

    func testTaskSummaryUpdatesLiveDetail() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.apply(.taskSummary("Printing hi"), to: &session, activity: &state, now: now)
        XCTAssertEqual(state.liveDetail, "Printing hi")
        SessionReducer.apply(.taskSummary(nil), to: &session, activity: &state, now: now)
        XCTAssertNil(state.liveDetail)
    }

    func testRecordedFixtureEndsAwaitingInput() throws {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.promptSent(to: &session, activity: &state, now: now)
        for event in try Fixtures.lines("stream-basic.jsonl").compactMap(StreamEventParser.parse) {
            SessionReducer.apply(event, to: &session, activity: &state, now: now)
        }
        XCTAssertEqual(session.status, .awaitingInput)
        XCTAssertEqual(session.summary, "done?")
        XCTAssertEqual(session.needsAction, "done?")
        XCTAssertFalse(state.isTurnActive)
        XCTAssertNil(state.liveDetail)
    }

    func testPostTurnSummaryCategoriesMapToStatuses() {
        let cases: [(String, SessionStatus)] = [("blocked", .awaitingInput), ("review_ready", .completed), ("done", .completed), ("failed", .completed)]
        for (category, expected) in cases {
            var session = makeSession()
            var state = SessionActivity()
            SessionReducer.promptSent(to: &session, activity: &state, now: now)
            SessionReducer.apply(.postTurnSummary(category: category, detail: "Round 2 review posted", needsAction: ""), to: &session, activity: &state, now: now)
            SessionReducer.apply(.result(ResultInfo(isError: false, subtype: "success", text: "ok", sessionID: nil, costUSD: nil, permissionDenials: 0)), to: &session, activity: &state, now: now)
            XCTAssertEqual(session.status, expected, category)
            XCTAssertEqual(session.summary, "Round 2 review posted")
            // Blocked with an empty needs_action falls back to the detail text.
            XCTAssertEqual(session.needsAction, expected == .awaitingInput ? "Round 2 review posted" : nil, category)
        }
    }

    func testWorkingPostSummaryWhileTurnActiveKeepsWorking() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.promptSent(to: &session, activity: &state, now: now)
        SessionReducer.apply(.postTurnSummary(category: "working", detail: "2 agents in flight", needsAction: nil), to: &session, activity: &state, now: now)
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.summary, "2 agents in flight")
    }

    func testPostSummaryArrivingAfterResultStillApplies() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.promptSent(to: &session, activity: &state, now: now)
        SessionReducer.apply(.result(ResultInfo(isError: false, subtype: "success", text: "All done.", sessionID: nil, costUSD: nil, permissionDenials: 0)), to: &session, activity: &state, now: now)
        XCTAssertEqual(session.status, .completed)
        SessionReducer.apply(.postTurnSummary(category: "blocked", detail: "Needs a decision on redirect strategy", needsAction: "Pick a redirect strategy"), to: &session, activity: &state, now: now)
        XCTAssertEqual(session.status, .awaitingInput)
        XCTAssertEqual(session.needsAction, "Pick a redirect strategy")
    }

    func testResultWithoutPostSummaryUsesHeuristics() {
        func finish(_ text: String?, denials: Int = 0, error: Bool = false) -> Session {
            var session = makeSession()
            var state = SessionActivity()
            SessionReducer.promptSent(to: &session, activity: &state, now: now)
            SessionReducer.apply(.result(ResultInfo(isError: error, subtype: error ? "error" : "success", text: text, sessionID: nil, costUSD: nil, permissionDenials: denials)), to: &session, activity: &state, now: now)
            return session
        }
        XCTAssertEqual(finish("Should I also update the docs?").status, .awaitingInput)
        XCTAssertEqual(finish("Opened PR #12.").status, .completed)
        XCTAssertEqual(finish("Done.", denials: 1).status, .awaitingInput)
        XCTAssertEqual(finish(nil, error: true).status, .completed)
        XCTAssertEqual(finish("First line\nSecond line").summary, "First line")
    }

    func testSummaryIsTruncated() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.apply(.result(ResultInfo(isError: false, subtype: "success", text: String(repeating: "a", count: 300), sessionID: nil, costUSD: nil, permissionDenials: 0)), to: &session, activity: &state, now: now)
        XCTAssertEqual(session.summary.count, SessionReducer.maxSummaryLength)
        XCTAssertTrue(session.summary.hasSuffix("…"))
    }

    func testPullRequestURLsAreCollectedFromToolResultsAndText() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.apply(.user(blocks: [.toolResult(toolUseID: "t", content: "https://github.com/Tim020/DigiScript/pull/1427\n", isError: false)], isSidechain: false), to: &session, activity: &state, now: now)
        SessionReducer.apply(.assistant(blocks: [.text("Opened https://github.com/Tim020/DigiScript/pull/1428 and see https://github.com/Tim020/DigiScript/pull/1427")], isSidechain: false), to: &session, activity: &state, now: now)
        XCTAssertEqual(session.pullRequestURLs, ["https://github.com/Tim020/DigiScript/pull/1427", "https://github.com/Tim020/DigiScript/pull/1428"])
    }

    func testProcessExitDuringTurnEndsIt() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.promptSent(to: &session, activity: &state, now: now)
        SessionReducer.processExited(session: &session, activity: &state, exitCode: 1, now: now)
        XCTAssertEqual(session.status, .completed)
        XCTAssertFalse(state.isTurnActive)
        XCTAssertEqual(state.transcript.lines.last?.kind, .error)
    }

    func testCleanExitAfterTurnAddsNothing() {
        var session = makeSession()
        var state = SessionActivity()
        SessionReducer.processExited(session: &session, activity: &state, exitCode: 0, now: now)
        XCTAssertTrue(state.transcript.lines.isEmpty)
    }
}
