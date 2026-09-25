import XCTest
@testable import SessionManagerCore

final class SessionDiscoveryTests: XCTestCase {
    let projectPath = "/Users/tim/Documents/Code/DigiScript"

    private func discovery() throws -> SessionDiscovery {
        SessionDiscovery(claudeHome: try Fixtures.url("claude-home"))
    }

    func testProjectDirectoryNameEncoding() {
        XCTAssertEqual(SessionDiscovery.directoryName(forProjectPath: "/Users/tim/Documents/Code/DigiScript"), "-Users-tim-Documents-Code-DigiScript")
        XCTAssertEqual(SessionDiscovery.directoryName(forProjectPath: "/home/claude/repo"), "-home-claude-repo")
        XCTAssertEqual(SessionDiscovery.directoryName(forProjectPath: "/Users/tim/my.app/v2_x"), "-Users-tim-my-app-v2-x")
    }

    func testDiscoversSessionsNewestFirstSkippingMetaOnlyFiles() throws {
        let sessions = try discovery().discover(projectPath: projectPath)
        XCTAssertEqual(sessions.map(\.claudeSessionID), [
            "aaaaaaaa-0000-0000-0000-000000000001",
            "bbbbbbbb-0000-0000-0000-000000000002",
        ])
    }

    func testExtractsTitleSummaryModelAndPullRequests() throws {
        let first = try XCTUnwrap(try discovery().discover(projectPath: projectPath).first)
        XCTAssertEqual(first.title, "investigate issue correlation")
        XCTAssertEqual(first.firstPrompt, "Investigate the issue correlation between the storage bug and the Jump to Page regression")
        XCTAssertEqual(first.summary, "2 agents in flight: storage fix (PR #1427) + Jump to Page regression.")
        XCTAssertEqual(first.model, "claude-opus-5-5")
        XCTAssertEqual(first.workingDirectory, projectPath)
        XCTAssertEqual(first.pullRequestURLs, ["https://github.com/Tim020/DigiScript/pull/1427"])
        XCTAssertEqual(first.lastActivity, ISO8601DateFormatter().date(from: "2026-09-25T05:00:00Z"))
        XCTAssertEqual(first.status, .completed)
    }

    func testCustomTitleWinsOverAITitleAndQuestionsAwaitInput() throws {
        let sessions = try discovery().discover(projectPath: projectPath)
        let review = try XCTUnwrap(sessions.first { $0.claudeSessionID.hasPrefix("bbbb") })
        XCTAssertEqual(review.title, "pr review inline 1427")
        XCTAssertEqual(review.status, .awaitingInput)
        XCTAssertEqual(review.role, .review)
    }

    func testMissingProjectDirectoryYieldsNoSessions() throws {
        XCTAssertEqual(try discovery().discover(projectPath: "/nowhere").count, 0)
    }

    func testTitleFallsBackToTruncatedFirstPrompt() {
        let lines = [
            #"{"type":"user","message":{"content":"Please evaluate the package managers we could use for the monorepo and write up a comparison"},"timestamp":"2026-09-25T04:50:00Z"}"#,
        ]
        let summary = SessionDiscovery.summarize(lines: lines, claudeSessionID: "x", fallbackDate: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(summary?.title, "Please evaluate the package managers we could use for the…")
        XCTAssertLessThanOrEqual(summary?.title.count ?? 0, SessionDiscovery.maxTitleLength)
    }

    func testLoadsTranscriptEventsFromHistory() throws {
        let events = try discovery().loadHistory(projectPath: projectPath, claudeSessionID: "aaaaaaaa-0000-0000-0000-000000000001")
        var builder = TranscriptBuilder(workingDirectory: projectPath)
        events.forEach { builder.apply($0) }
        XCTAssertEqual(builder.lines.map(\.kind), [.prompt, .tool, .assistant])
        XCTAssertEqual(builder.lines[1].text, "Read server/digi_server/models/storage.py")
    }

    func testHistoryForUnknownSessionIsEmpty() throws {
        XCTAssertEqual(try discovery().loadHistory(projectPath: projectPath, claudeSessionID: "nope"), [])
    }

    func testMakeSessionFromDiscovered() throws {
        let discovered = try XCTUnwrap(try discovery().discover(projectPath: projectPath).first)
        let projectID = UUID()
        let session = discovered.makeSession(projectID: projectID)
        XCTAssertEqual(session.projectID, projectID)
        XCTAssertEqual(session.name, "investigate issue correlation")
        XCTAssertEqual(session.claudeSessionID, discovered.claudeSessionID)
        XCTAssertTrue(session.hasConversation)
        XCTAssertEqual(session.summary, discovered.summary)
        XCTAssertEqual(session.workingDirectory, projectPath)
    }
}

final class WorkspaceImportTests: XCTestCase {
    func testImportAddsNewSessionsAsUnfiledAndUpdatesKnownOnes() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        var existing = Session(projectID: p, claudeSessionID: "known", hasConversation: true, name: "my name", workingDirectory: "/code/app",
                               summary: "old", createdAt: old)
        existing.status = .completed
        try ws.addSession(existing)

        let discovered = [
            DiscoveredSession(claudeSessionID: "known", title: "ai title", firstPrompt: "p", summary: "newer summary", model: "m",
                              workingDirectory: "/code/app", lastActivity: new, pullRequestURLs: ["https://github.com/a/b/pull/1"], status: .awaitingInput),
            DiscoveredSession(claudeSessionID: "fresh", title: "fresh one", firstPrompt: "p", summary: "s", model: nil,
                              workingDirectory: "/code/app", lastActivity: new, pullRequestURLs: [], status: .completed),
        ]
        let added = ws.importDiscovered(discovered, into: p, skipping: [])

        XCTAssertEqual(added, 1)
        let known = try XCTUnwrap(ws.session(claudeSessionID: "known"))
        XCTAssertEqual(known.name, "my name", "user-chosen names are kept")
        XCTAssertEqual(known.summary, "newer summary")
        XCTAssertEqual(known.status, .awaitingInput)
        XCTAssertEqual(known.lastActivity, new)
        XCTAssertEqual(known.pullRequestURLs, ["https://github.com/a/b/pull/1"])
        XCTAssertEqual(ws.sessions(in: .unfiled(projectID: p)).map(\.name).sorted(), ["fresh one", "my name"])
    }

    func testImportDoesNotTouchSessionsThatAreRunningOrOlder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = Session(projectID: p, claudeSessionID: "busy", hasConversation: true, name: "busy", workingDirectory: "/code/app",
                        status: .working, summary: "live", createdAt: Date(timeIntervalSince1970: 500))
        try ws.addSession(s)
        let stale = DiscoveredSession(claudeSessionID: "busy", title: "t", firstPrompt: "p", summary: "stale", model: nil,
                                      workingDirectory: "/code/app", lastActivity: Date(timeIntervalSince1970: 900), pullRequestURLs: [], status: .completed)
        _ = ws.importDiscovered([stale], into: p, skipping: [s.id])
        XCTAssertEqual(ws.session(s.id)?.summary, "live")
        XCTAssertEqual(ws.session(s.id)?.status, .working)
    }
}
