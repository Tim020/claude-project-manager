import XCTest
@testable import ClaudioCore

final class SidebarWidthTests: XCTestCase {
    func testWidthIsClampedAndPersisted() throws {
        XCTAssertEqual(AppSettings().sidebarWidth, 290)
        XCTAssertEqual(AppSettings.clampSidebarWidth(100), AppSettings.sidebarWidthRange.lowerBound)
        XCTAssertEqual(AppSettings.clampSidebarWidth(2000), AppSettings.sidebarWidthRange.upperBound)
        XCTAssertEqual(AppSettings.clampSidebarWidth(333), 333)

        var settings = AppSettings()
        settings.sidebarWidth = 350
        let decoded = try JSONFileStore.decoder.decode(AppSettings.self, from: JSONFileStore.encoder.encode(settings))
        XCTAssertEqual(decoded.sidebarWidth, 350)
    }
}

final class ReorderTests: XCTestCase {
    private var ws = Workspace()
    private var p = UUID(), f = UUID()
    private var a = UUID(), b = UUID(), c = UUID()

    override func setUpWithError() throws {
        ws = Workspace()
        p = ws.addProject(path: "/code")
        f = try ws.createFolder(in: p, named: "F")
        for name in ["a", "b", "c"] {
            let s = Session(projectID: p, name: name, workingDirectory: "/code")
            try ws.addSession(s, toFolder: f)
        }
        (a, b, c) = (ws.folder(f)!.sessionIDs[0], ws.folder(f)!.sessionIDs[1], ws.folder(f)!.sessionIDs[2])
    }

    func testMoveBeforeAnotherSessionInTheSameFolder() throws {
        try ws.moveSession(c, before: a)
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [c, a, b])
        try ws.moveSession(c, before: b)
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [a, c, b])
        try ws.moveSession(a, before: a)
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [a, c, b], "dropping on itself changes nothing")
    }

    func testMoveBeforeASessionInAnotherFolder() throws {
        let g = try ws.createFolder(in: p, named: "G")
        let d = Session(projectID: p, name: "d", workingDirectory: "/code")
        try ws.addSession(d, toFolder: g)
        try ws.moveSession(b, before: d.id)
        XCTAssertEqual(ws.folder(g)?.sessionIDs, [b, d.id])
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [a, c])
    }

    func testMoveBeforeAnUnfiledSessionUnfiles() throws {
        let u = Session(projectID: p, name: "u", workingDirectory: "/code")
        try ws.addSession(u)
        try ws.moveSession(a, before: u.id)
        XCTAssertEqual(ws.group(of: a), .unfiled(projectID: p))
    }

    func testMoveToTheEndOfAFolder() throws {
        try ws.moveSession(a, to: .folder(f))
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [b, c, a])
    }
}

final class FolderCollapseTests: XCTestCase {
    func testFoldersAndUnfiledCollapseIndependently() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let f = try ws.createFolder(in: p, named: "F")
        try ws.addSession(Session(projectID: p, name: "in folder", workingDirectory: "/code"), toFolder: f)
        try ws.addSession(Session(projectID: p, name: "loose", workingDirectory: "/code"))

        ws.toggleCollapsed(.folder(f))
        XCTAssertTrue(ws.isCollapsed(.folder(f)))
        XCTAssertFalse(ws.isCollapsed(.unfiled(projectID: p)))

        var tree = Sidebar.build(ws, filter: "", home: "/")
        XCTAssertEqual(tree[0].folders.map(\.isCollapsed), [true, false])
        XCTAssertEqual(tree[0].folders[0].sessions, [], "collapsed folders hide their sessions")
        XCTAssertEqual(tree[0].folders[0].sessionCount, 1, "but still show the count")

        ws.toggleCollapsed(.unfiled(projectID: p))
        tree = Sidebar.build(ws, filter: "", home: "/")
        XCTAssertTrue(tree[0].folders[1].isCollapsed)

        let filtered = Sidebar.build(ws, filter: "folder", home: "/")
        XCTAssertEqual(filtered[0].folders[0].sessions.map(\.name), ["in folder"], "filtering shows matches in collapsed folders")
    }

    func testCollapseStatePersistsAndOldFilesDecode() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let f = try ws.createFolder(in: p, named: "F")
        ws.toggleCollapsed(.folder(f))
        ws.toggleCollapsed(.unfiled(projectID: p))
        let decoded = try JSONFileStore.decoder.decode(Workspace.self, from: JSONFileStore.encoder.encode(ws))
        XCTAssertTrue(decoded.isCollapsed(.folder(f)))
        XCTAssertTrue(decoded.isCollapsed(.unfiled(projectID: p)))

        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"F","sessionIDs":[]}"#
        XCTAssertFalse(try JSONFileStore.decoder.decode(Folder.self, from: Data(old.utf8)).isCollapsed)
    }
}

/// Test bodies hop to the main actor explicitly: a `@MainActor` test class
/// breaks test discovery on Linux.
final class NavigationModelTests: XCTestCase {
    func testModelReordersCollapsesAndStoresWidth() throws {
        try MainActor.assumeIsolated {
            let store = MemoryStore()
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            let p = model.addProject(path: "/code")
            let f = try XCTUnwrap(model.createFolder(in: p))
            var settings = model.settings
            settings.useBackgroundAgents = false
            model.updateSettings(settings)
            let request = NewSessionRequest(projectID: p, folderID: f, name: "x", role: .code, prompt: "", model: nil, permissionMode: .standard)
            let a = try XCTUnwrap(model.createSession(request))
            let b = try XCTUnwrap(model.createSession(request))
            model.moveSession(b, before: a)
            XCTAssertEqual(model.workspace.folder(f)?.sessionIDs, [b, a])

            model.toggleCollapsed(.folder(f))
            XCTAssertTrue(store.state.workspace.isCollapsed(.folder(f)))

            model.setSidebarWidth(9999)
            XCTAssertEqual(store.state.settings.sidebarWidth, AppSettings.sidebarWidthRange.upperBound)
        }
    }
}
