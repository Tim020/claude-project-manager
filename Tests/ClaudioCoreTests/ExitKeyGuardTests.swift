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

        // Folders count their own sessions, collapsed or filtered or not.
        ws.toggleCollapsed(p)
        ws.toggleCollapsed(.folder(f))
        let folders = try XCTUnwrap(Sidebar.build(ws, filter: "", home: "/").first { $0.id == p }?.folders)
        XCTAssertEqual(folders.first { $0.name == "F" }?.statusCounts, StatusCounts(working: 1))
        XCTAssertEqual(folders.first { $0.isUnfiled }?.statusCounts, StatusCounts(awaitingInput: 1, completed: 1))
        let filtered = Sidebar.build(ws, filter: "", status: .completed, home: "/").first { $0.id == p }?.folders
        XCTAssertEqual(filtered?.first { $0.isUnfiled }?.statusCounts, StatusCounts(awaitingInput: 1, completed: 1),
                       "a status filter hides sessions but not their counts")
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
