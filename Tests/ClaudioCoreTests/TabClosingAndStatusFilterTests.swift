import XCTest
@testable import ClaudioCore

final class TabClosingTests: XCTestCase {
    private func workspace() throws -> (Workspace, [Session]) {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let sessions = ["a", "b", "c", "d"].map { Session(projectID: p, name: $0, workingDirectory: "/code") }
        for s in sessions { try ws.addSession(s); ws.openTab(s.id) }
        return (ws, sessions)
    }

    func testCloseTabsToTheLeftAndRight() throws {
        var (ws, s) = try workspace()
        ws.closeTabs(rightOf: s[1].id)
        XCTAssertEqual(ws.openTabSessions.map(\.name), ["a", "b"])

        (ws, s) = try workspace()
        ws.closeTabs(leftOf: s[2].id)
        XCTAssertEqual(ws.openTabSessions.map(\.name), ["c", "d"])

        (ws, s) = try workspace()
        ws.closeTabs(leftOf: s[0].id)
        ws.closeTabs(rightOf: s[3].id)
        XCTAssertEqual(ws.openTabSessions.count, 4, "nothing beyond the ends")
    }

    func testTabsToEitherSide() throws {
        let (ws, s) = try workspace()
        XCTAssertEqual(ws.tabIDs(leftOf: s[2].id), [s[0].id, s[1].id])
        XCTAssertEqual(ws.tabIDs(rightOf: s[2].id), [s[3].id])
        XCTAssertEqual(ws.tabIDs(rightOf: UUID()), [])
    }

    func testCloseAllTabs() throws {
        var (ws, s) = try workspace()
        ws.closeAllTabs()
        XCTAssertTrue(ws.openTabSessions.isEmpty)
        XCTAssertNotNil(ws.session(s[0].id), "sessions stay")
    }

    @MainActor private func model() throws -> (AppModel, [Session]) {
        var state = PersistedState()
        let (ws, s) = try workspace()
        state.workspace = ws
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        return (model, s)
    }

    func testModelKeepsTheAnchorSelectedWhenTheSelectionCloses() throws {
        try MainActor.assumeIsolated {
            let (model, s) = try model()
            model.select(s[3].id)
            model.closeTabs(leftOf: s[3].id)
            XCTAssertEqual(model.tabs.map(\.name), ["d"])
            XCTAssertEqual(model.selectedSessionID, s[3].id)

            let (other, t) = try self.model()
            other.select(t[3].id)
            other.closeTabs(rightOf: t[1].id)
            XCTAssertEqual(other.tabs.map(\.name), ["a", "b"])
            XCTAssertEqual(other.selectedSessionID, t[1].id, "the clicked tab takes over when the selected one closes")

            let (keep, u) = try self.model()
            keep.select(u[0].id)
            keep.closeTabs(rightOf: u[1].id)
            XCTAssertEqual(keep.selectedSessionID, u[0].id, "an open selection stays")
        }
    }

    func testModelCloseAllTabsClearsTheSelection() throws {
        try MainActor.assumeIsolated {
            let (model, s) = try model()
            model.select(s[1].id)
            model.closeAllTabs()
            XCTAssertTrue(model.tabs.isEmpty)
            XCTAssertNil(model.selectedSessionID)
        }
    }
}

final class StatusFilterTests: XCTestCase {
    private func workspace() throws -> Workspace {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let other = ws.addProject(path: "/other")
        let f = try ws.createFolder(in: p, named: "Feature")
        try ws.addSession(Session(projectID: p, name: "busy", workingDirectory: "/code", status: .working), toFolder: f)
        try ws.addSession(Session(projectID: p, name: "asks", workingDirectory: "/code", status: .awaitingInput), toFolder: f)
        try ws.addSession(Session(projectID: p, name: "done", workingDirectory: "/code", status: .completed))
        try ws.addSession(Session(projectID: other, name: "old", workingDirectory: "/other", status: .completed))
        ws.toggleCollapsed(.folder(f))
        return ws
    }

    private func names(_ tree: [SidebarProject]) -> [String] {
        tree.flatMap { $0.folders.flatMap { $0.sessions.map(\.name) } }
    }

    func testNoStatusFilterShowsEverything() throws {
        let tree = Sidebar.build(try workspace(), filter: "", status: nil, home: "/")
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(names(tree), ["done", "old"], "the collapsed folder hides its sessions")
    }

    func testStatusFilterShowsOnlyMatchingSessionsEvenInCollapsedFolders() throws {
        let ws = try workspace()
        XCTAssertEqual(names(Sidebar.build(ws, filter: "", status: .awaitingInput, home: "/")), ["asks"])
        XCTAssertEqual(names(Sidebar.build(ws, filter: "", status: .working, home: "/")), ["busy"])
        let completed = Sidebar.build(ws, filter: "", status: .completed, home: "/")
        XCTAssertEqual(names(completed), ["done", "old"])
        XCTAssertEqual(completed.first?.folders.map(\.name), [Workspace.unfiledName], "empty folders are dropped")
        XCTAssertEqual(Sidebar.build(ws, filter: "", status: .working, home: "/").count, 1, "empty projects are dropped")
    }

    func testStatusAndTextFiltersCombine() throws {
        let ws = try workspace()
        XCTAssertEqual(names(Sidebar.build(ws, filter: "old", status: .completed, home: "/")), ["old"])
        XCTAssertEqual(names(Sidebar.build(ws, filter: "busy", status: .completed, home: "/")), [])
    }

    func testModelStatusFilterTogglesOff() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            state.workspace = try workspace()
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            // (Working sessions are reset to Completed at launch.)
            model.toggleStatusFilter(.awaitingInput)
            XCTAssertEqual(model.statusFilter, .awaitingInput)
            XCTAssertEqual(names(model.sidebar), ["asks"])
            model.toggleStatusFilter(.completed)
            XCTAssertEqual(model.statusFilter, .completed)
            model.toggleStatusFilter(.completed)
            XCTAssertNil(model.statusFilter)
        }
    }
}
