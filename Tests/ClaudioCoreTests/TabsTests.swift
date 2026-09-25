import XCTest
@testable import ClaudioCore

final class WorkspaceTabTests: XCTestCase {
    func testOpenAndCloseTabs() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let a = Session(projectID: p, name: "a", workingDirectory: "/code")
        try ws.addSession(a)
        XCTAssertFalse(ws.isOpen(a.id))
        ws.openTab(a.id)
        XCTAssertTrue(ws.isOpen(a.id))
        ws.closeTab(a.id)
        XCTAssertFalse(ws.isOpen(a.id))
        XCTAssertNotNil(ws.session(a.id), "closing a tab keeps the session")
    }

    func testOpenTabsFollowFolderOrderAndStayWithTheirFolder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let f1 = try ws.createFolder(in: p, named: "One")
        let f2 = try ws.createFolder(in: p, named: "Two")
        let a = Session(projectID: p, name: "a", workingDirectory: "/code")
        let b = Session(projectID: p, name: "b", workingDirectory: "/code")
        let c = Session(projectID: p, name: "c", workingDirectory: "/code")
        for s in [a, b, c] { try ws.addSession(s, toFolder: f1) }
        ws.openTab(c.id)
        ws.openTab(a.id)
        XCTAssertEqual(ws.openSessions(in: .folder(f1)).map(\.name), ["a", "c"])
        XCTAssertEqual(ws.openSessions(in: .folder(f2)), [])

        try ws.moveSession(c.id, to: .folder(f2))
        XCTAssertEqual(ws.openSessions(in: .folder(f2)).map(\.name), ["c"], "open state travels with the session")
    }

    func testCloseOtherAndCompletedTabs() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let f = try ws.createFolder(in: p, named: "F")
        let done = Session(projectID: p, name: "done", workingDirectory: "/code", status: .completed)
        let busy = Session(projectID: p, name: "busy", workingDirectory: "/code", status: .working)
        let waiting = Session(projectID: p, name: "waiting", workingDirectory: "/code", status: .awaitingInput)
        for s in [done, busy, waiting] { try ws.addSession(s, toFolder: f); ws.openTab(s.id) }

        ws.closeCompletedTabs(in: .folder(f))
        XCTAssertEqual(ws.openSessions(in: .folder(f)).map(\.name), ["busy", "waiting"])

        ws.closeOtherTabs(keeping: busy.id)
        XCTAssertEqual(ws.openSessions(in: .folder(f)).map(\.name), ["busy"])
    }

    func testCloseOtherTabsAffectsEveryFolder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let f1 = try ws.createFolder(in: p, named: "One")
        let f2 = try ws.createFolder(in: p, named: "Two")
        let a = Session(projectID: p, name: "a", workingDirectory: "/code")
        let b = Session(projectID: p, name: "b", workingDirectory: "/code")
        try ws.addSession(a, toFolder: f1)
        try ws.addSession(b, toFolder: f2)
        ws.openTab(a.id)
        ws.openTab(b.id)
        ws.closeOtherTabs(keeping: a.id)
        XCTAssertFalse(ws.isOpen(b.id), "tabs aren't per folder any more")
    }

    func testRemovingASessionForgetsItsTab() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let a = Session(projectID: p, name: "a", workingDirectory: "/code")
        try ws.addSession(a)
        ws.openTab(a.id)
        ws.removeSession(a.id)
        XCTAssertTrue(ws.openSessionIDs.isEmpty)
    }

    func testImportedSessionsStartClosed() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        ws.importDiscovered([DiscoveredSession(claudeSessionID: "x", title: "t", firstPrompt: "p", summary: "", model: nil,
                                               workingDirectory: "/code", lastActivity: Date(), pullRequestURLs: [], status: .completed)],
                            into: p, skipping: [])
        XCTAssertTrue(ws.openSessionIDs.isEmpty)
    }

    func testOpenTabsPersistAndOldFilesDecode() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let a = Session(projectID: p, name: "a", workingDirectory: "/code")
        try ws.addSession(a)
        ws.openTab(a.id)
        let decoded = try JSONFileStore.decoder.decode(Workspace.self, from: JSONFileStore.encoder.encode(ws))
        XCTAssertEqual(decoded.openSessionIDs, [a.id])

        let old = try JSONFileStore.decoder.decode(Workspace.self, from: Data(#"{"projects":[],"sessions":[]}"#.utf8))
        XCTAssertTrue(old.openSessionIDs.isEmpty)
    }
}

final class SplitLayoutTests: XCTestCase {
    let ids = (0..<6).map { _ in UUID() }

    func testGridFitsPanesAboveMinimumSize() {
        XCTAssertEqual(SplitLayout.grid(paneCount: 2, width: 1000, height: 600), .init(columns: 2, rows: 1))
        XCTAssertEqual(SplitLayout.grid(paneCount: 4, width: 1000, height: 700), .init(columns: 2, rows: 2))
        XCTAssertEqual(SplitLayout.grid(paneCount: 3, width: 1000, height: 700), .init(columns: 2, rows: 2))
        XCTAssertEqual(SplitLayout.grid(paneCount: 4, width: 1000, height: 500), .init(columns: 2, rows: 1), "too short for two rows")
        XCTAssertEqual(SplitLayout.grid(paneCount: 3, width: 700, height: 900), .init(columns: 1, rows: 2), "too narrow for two columns")
        XCTAssertEqual(SplitLayout.grid(paneCount: 1, width: 300, height: 200), .init(columns: 1, rows: 1))
        XCTAssertEqual(SplitLayout.grid(paneCount: 0, width: 1000, height: 700), .init(columns: 1, rows: 1))
    }

    func testCapacityIsCapped() {
        XCTAssertEqual(SplitLayout.grid(paneCount: 9, width: 4000, height: 3000).capacity, SplitLayout.maxPanes)
    }

    func testPanesKeepTabOrderWhenAllFit() {
        let panes = SplitLayout.panes(open: Array(ids.prefix(3)), selected: ids[2], recent: [ids[2], ids[0]], capacity: 4)
        XCTAssertEqual(panes, Array(ids.prefix(3)))
    }

    func testOverflowKeepsSelectedAndMostRecentInTabOrder() {
        let open = Array(ids.prefix(6))
        let panes = SplitLayout.panes(open: open, selected: ids[5], recent: [ids[5], ids[1], ids[3], ids[0], ids[2]], capacity: 3)
        XCTAssertEqual(panes, [ids[1], ids[3], ids[5]])
    }

    func testOverflowFillsWithTabOrderWhenHistoryIsShort() {
        let panes = SplitLayout.panes(open: Array(ids.prefix(5)), selected: ids[4], recent: [], capacity: 2)
        XCTAssertEqual(panes, [ids[0], ids[4]])
    }
}
