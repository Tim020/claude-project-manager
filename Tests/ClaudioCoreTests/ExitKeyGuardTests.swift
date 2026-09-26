import XCTest
@testable import ClaudioCore

/// Claude Code exits on a second Ctrl+C (or Ctrl+D) on an empty prompt. Text
/// recorded from 2.1.283 in a pseudo-terminal: "Press Ctrl-C again to exit".
final class ExitKeyGuardTests: XCTestCase {
    private func screen(_ hint: String) -> [String] {
        ["────────────────", "❯ ", "────────────────", "\(hint)", "⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]
    }

    func testRecognisesExitKeysInEveryEncoding() {
        XCTAssertEqual(ExitKeyGuard.exitKey([0x03]), .ctrlC)
        XCTAssertEqual(ExitKeyGuard.exitKey([0x04]), .ctrlD)
        XCTAssertEqual(ExitKeyGuard.exitKey(Array("\u{1B}[99;5u".utf8)), .ctrlC, "kitty keyboard protocol")
        XCTAssertEqual(ExitKeyGuard.exitKey(Array("\u{1B}[100;5u".utf8)), .ctrlD)
        XCTAssertEqual(ExitKeyGuard.exitKey(Array("\u{1B}[27;5;99~".utf8)), .ctrlC, "xterm modifyOtherKeys")
        XCTAssertNil(ExitKeyGuard.exitKey(Array("c".utf8)))
        XCTAssertNil(ExitKeyGuard.exitKey([0x03, 0x03]), "pasted text isn't a key press")
    }

    func testBlocksTheSecondPressWhileClaudeAsksToConfirm() {
        XCTAssertTrue(ExitKeyGuard.shouldBlock(input: [0x03], screen: screen("Press Ctrl-C again to exit"), secondsSinceSameKey: nil))
        XCTAssertTrue(ExitKeyGuard.shouldBlock(input: [0x04], screen: screen("Press Ctrl-D again to exit"), secondsSinceSameKey: nil))
    }

    func testBlocksARapidSecondPressEvenBeforeTheHintIsDrawn() {
        XCTAssertTrue(ExitKeyGuard.shouldBlock(input: [0x03], screen: screen(""), secondsSinceSameKey: 0.3))
        XCTAssertFalse(ExitKeyGuard.shouldBlock(input: [0x03], screen: screen(""), secondsSinceSameKey: 5))
    }

    func testASinglePressStillReachesClaude() {
        // One Ctrl+C interrupts a running turn or clears the prompt.
        XCTAssertFalse(ExitKeyGuard.shouldBlock(input: [0x03], screen: screen(""), secondsSinceSameKey: nil))
        XCTAssertFalse(ExitKeyGuard.shouldBlock(input: Array("a".utf8), screen: screen("Press Ctrl-C again to exit"), secondsSinceSameKey: 0.1))
    }
}

final class ProjectStatusCountTests: XCTestCase {
    func testProjectHeaderCountsEachStatus() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let other = ws.addProject(path: "/other")
        let f = try ws.createFolder(in: p, named: "F")
        try ws.addSession(Session(projectID: p, name: "a", workingDirectory: "/code", status: .working), toFolder: f)
        try ws.addSession(Session(projectID: p, name: "b", workingDirectory: "/code", status: .awaitingInput))
        try ws.addSession(Session(projectID: p, name: "c", workingDirectory: "/code", status: .completed))
        try ws.addSession(Session(projectID: p, name: "d", workingDirectory: "/code", status: .completed, isArchived: true))
        try ws.addSession(Session(projectID: other, name: "e", workingDirectory: "/other", status: .working))
        ws.toggleCollapsed(p)

        let tree = Sidebar.build(ws, filter: "", home: "/")
        let code = try XCTUnwrap(tree.first { $0.id == p })
        XCTAssertEqual(code.statusCounts, StatusCounts(working: 1, awaitingInput: 1, completed: 1), "archived don't count; collapsed still counts")
        XCTAssertEqual(tree.first { $0.id == other }?.statusCounts, StatusCounts(working: 1))

        // Folders count their own sessions, collapsed or not.
        ws.toggleCollapsed(p)
        ws.toggleCollapsed(.folder(f))
        let folders = try XCTUnwrap(Sidebar.build(ws, filter: "", home: "/").first { $0.id == p }?.folders)
        XCTAssertEqual(folders.first { $0.name == "F" }?.statusCounts, StatusCounts(working: 1))
        XCTAssertEqual(folders.first { $0.isUnfiled }?.statusCounts, StatusCounts(awaitingInput: 1, completed: 1))
    }

    func testCountsMatchWhatTheFiltersShow() throws {
        let now = Date(timeIntervalSince1970: 1_790_352_000)
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let f = try ws.createFolder(in: p, named: "F")
        func add(_ name: String, _ status: SessionStatus, daysAgo: Double, folder: UUID? = nil) throws {
            let when = now.addingTimeInterval(-daysAgo * 86_400)
            try ws.addSession(Session(projectID: p, name: name, workingDirectory: "/code", status: status,
                                      createdAt: when, lastActivity: when), toFolder: folder)
        }
        try add("busy api", .working, daysAgo: 1, folder: f)
        try add("done api", .completed, daysAgo: 2, folder: f)
        try add("old api", .completed, daysAgo: 30, folder: f)
        try add("asks ui", .awaitingInput, daysAgo: 1)

        func counts(_ tree: [SidebarProject]) -> (project: StatusCounts?, folder: StatusCounts?) {
            let project = tree.first { $0.id == p }
            return (project?.statusCounts, project?.folders.first { $0.name == "F" }?.statusCounts)
        }

        var c = counts(Sidebar.build(ws, filter: "", home: "/"))
        XCTAssertEqual(c.project, StatusCounts(working: 1, awaitingInput: 1, completed: 2))
        XCTAssertEqual(c.folder, StatusCounts(working: 1, completed: 2))

        c = counts(Sidebar.build(ws, filter: "", activeSince: now.addingTimeInterval(-14 * 86_400), home: "/"))
        XCTAssertEqual(c.project, StatusCounts(working: 1, awaitingInput: 1, completed: 1), "old sessions hidden by the window aren't counted")
        XCTAssertEqual(c.folder, StatusCounts(working: 1, completed: 1))

        c = counts(Sidebar.build(ws, filter: "", status: .completed, home: "/"))
        XCTAssertEqual(c.project, StatusCounts(completed: 2), "a status filter leaves only its own pill")
        XCTAssertEqual(c.folder, StatusCounts(completed: 2))

        c = counts(Sidebar.build(ws, filter: "api", home: "/"))
        XCTAssertEqual(c.project, StatusCounts(working: 1, completed: 2), "the text filter narrows the counts too")

        c = counts(Sidebar.build(ws, filter: "code", home: "/"))
        XCTAssertEqual(c.project, StatusCounts(working: 1, awaitingInput: 1, completed: 2), "a matching project shows (and counts) everything")
    }
}

final class TerminalHintTests: XCTestCase {
    func testBlockedExitShowsAHintUntilCleared() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            var agent = Session(projectID: p, name: "a", workingDirectory: "/code")
            agent.agentID = "abcd1234"
            let direct = Session(projectID: p, name: "d", workingDirectory: "/code")
            try state.workspace.addSession(agent)
            try state.workspace.addSession(direct)
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            model.exitKeyBlocked(agent.id)
            model.exitKeyBlocked(direct.id)
            XCTAssertTrue(model.terminalHints[agent.id]?.contains("Close the tab to detach") ?? false)
            XCTAssertTrue(model.terminalHints[direct.id]?.contains("Stop Session") ?? false)
            model.clearTerminalHint(agent.id)
            XCTAssertNil(model.terminalHints[agent.id])
        }
    }
}

final class FooterCountTests: XCTestCase {
    func testFooterFollowsTextAndWindowButNotTheStatusFilter() throws {
        let now = Date(timeIntervalSince1970: 1_790_352_000)
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            func add(_ name: String, _ status: SessionStatus, daysAgo: Double) throws {
                let when = now.addingTimeInterval(-daysAgo * 86_400)
                try state.workspace.addSession(Session(projectID: p, name: name, workingDirectory: "/code", status: status,
                                                       createdAt: when, lastActivity: when))
            }
            try add("asks api", .awaitingInput, daysAgo: 1)
            try add("done api", .completed, daysAgo: 2)
            try add("old api", .completed, daysAgo: 30)
            try add("asks ui", .awaitingInput, daysAgo: 1)
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", now: { now }, home: "/")

            XCTAssertEqual(model.footerStatusCounts, StatusCounts(awaitingInput: 2, completed: 1), "the 2-week window hides the old one")
            model.toggleStatusFilter(.completed)
            XCTAssertEqual(model.footerStatusCounts, StatusCounts(awaitingInput: 2, completed: 1), "the status filter doesn't change the footer")
            model.filterText = "api"
            XCTAssertEqual(model.footerStatusCounts, StatusCounts(awaitingInput: 1, completed: 1))
            XCTAssertEqual(model.awaitingInputCount, 2, "the Dock badge still counts everything")
        }
    }
}
