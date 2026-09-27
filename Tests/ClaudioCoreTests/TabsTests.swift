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
