import XCTest
@testable import ClaudioCore

final class WorkspaceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(_ name: String, project: UUID, status: SessionStatus = .completed, activity: TimeInterval = 0) -> Session {
        Session(projectID: project, name: name, workingDirectory: "/tmp", status: status, createdAt: t0, lastActivity: t0.addingTimeInterval(activity))
    }

    // MARK: Projects

    func testAddProjectDefaultsNameToLastPathComponent() {
        var ws = Workspace()
        let id = ws.addProject(path: "/Users/tim/Documents/Code/DigiScript/")
        XCTAssertEqual(ws.project(id)?.name, "DigiScript")
        XCTAssertEqual(ws.project(id)?.path, "/Users/tim/Documents/Code/DigiScript")
    }

    func testAddingSameProjectPathTwiceReturnsExistingProject() {
        var ws = Workspace()
        let a = ws.addProject(path: "/code/app")
        let b = ws.addProject(path: "/code/app/")
        XCTAssertEqual(a, b)
        XCTAssertEqual(ws.projects.count, 1)
    }

    func testRemoveProjectRemovesItsSessions() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let other = ws.addProject(path: "/code/other")
        try ws.addSession(makeSession("a", project: p))
        try ws.addSession(makeSession("b", project: other))
        ws.removeProject(p)
        XCTAssertEqual(ws.projects.map(\.id), [other])
        XCTAssertEqual(ws.sessions.map(\.name), ["b"])
    }

    // MARK: Folders

    func testCreateFolderTrimsName() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let f = try ws.createFolder(in: p, named: "  Storage fix — PR #1427 ")
        XCTAssertEqual(ws.folder(f)?.name, "Storage fix — PR #1427")
        XCTAssertEqual(ws.projectID(containingFolder: f), p)
    }

    func testCreateFolderWithBlankNameGetsUniqueDefaultName() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let a = try ws.createFolder(in: p, named: "")
        let b = try ws.createFolder(in: p, named: "   ")
        XCTAssertEqual(ws.folder(a)?.name, "New Folder")
        XCTAssertEqual(ws.folder(b)?.name, "New Folder 2")
    }

    func testCreateFolderInUnknownProjectThrows() {
        var ws = Workspace()
        XCTAssertThrowsError(try ws.createFolder(in: UUID(), named: "x")) { error in
            XCTAssertEqual(error as? WorkspaceError, .projectNotFound)
        }
    }

    func testRenameFolder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let f = try ws.createFolder(in: p, named: "Old")
        try ws.renameFolder(f, to: " Mic planner perf ")
        XCTAssertEqual(ws.folder(f)?.name, "Mic planner perf")
    }

    func testRenameFolderToBlankThrowsAndKeepsName() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let f = try ws.createFolder(in: p, named: "Keep")
        XCTAssertThrowsError(try ws.renameFolder(f, to: "  ")) { error in
            XCTAssertEqual(error as? WorkspaceError, .emptyName)
        }
        XCTAssertEqual(ws.folder(f)?.name, "Keep")
    }

    func testDeleteFolderMovesSessionsToUnfiled() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let f = try ws.createFolder(in: p, named: "F")
        let s = makeSession("s", project: p)
        try ws.addSession(s, toFolder: f)
        ws.deleteFolder(f)
        XCTAssertNil(ws.folder(f))
        XCTAssertEqual(ws.group(of: s.id), .unfiled(projectID: p))
        XCTAssertNotNil(ws.session(s.id))
    }

    func testMoveFolderToAnotherProjectMovesItsSessions() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        let f = try ws.createFolder(in: p1, named: "F")
        let s = makeSession("s", project: p1)
        try ws.addSession(s, toFolder: f)
        try ws.moveFolder(f, toProject: p2)
        XCTAssertEqual(ws.projectID(containingFolder: f), p2)
        XCTAssertEqual(ws.session(s.id)?.projectID, p2)
        XCTAssertTrue(ws.project(p1)!.folders.isEmpty)
        // The session keeps its own working directory so it can still be resumed.
        XCTAssertEqual(ws.session(s.id)?.workingDirectory, "/tmp")
    }

    func testMoveFolderBeforeAnotherReorders() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let a = try ws.createFolder(in: p, named: "A")
        let b = try ws.createFolder(in: p, named: "B")
        let c = try ws.createFolder(in: p, named: "C")
        try ws.moveFolder(c, before: a, inProject: p)
        XCTAssertEqual(ws.project(p)!.folders.map(\.name), ["C", "A", "B"])
        try ws.moveFolder(c, before: nil, inProject: p)
        XCTAssertEqual(ws.project(p)!.folders.map(\.name), ["A", "B", "C"])
        try ws.moveFolder(b, before: b, inProject: p)
        XCTAssertEqual(ws.project(p)!.folders.map(\.name), ["A", "B", "C"], "dropping on itself changes nothing")
    }

    func testMoveFolderBeforeOneInAnotherProjectMovesItsSessions() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        let moving = try ws.createFolder(in: p1, named: "Moving")
        let target = try ws.createFolder(in: p2, named: "Target")
        let s = makeSession("s", project: p1)
        try ws.addSession(s, toFolder: moving)
        try ws.moveFolder(moving, before: target, inProject: p2)
        XCTAssertEqual(ws.project(p2)!.folders.map(\.name), ["Moving", "Target"])
        XCTAssertTrue(ws.project(p1)!.folders.isEmpty)
        XCTAssertEqual(ws.session(s.id)?.projectID, p2)
    }

    func testMoveFolderDownBeforeALaterOne() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let a = try ws.createFolder(in: p, named: "A")
        _ = try ws.createFolder(in: p, named: "B")
        let c = try ws.createFolder(in: p, named: "C")
        try ws.moveFolder(a, before: c, inProject: p)
        XCTAssertEqual(ws.project(p)!.folders.map(\.name), ["B", "A", "C"])
    }

    /// A project takes the target's place: after it going down, before it going up.
    func testMoveProjectOntoAnother() {
        var ws = Workspace()
        let a = ws.addProject(path: "/code/a")
        let b = ws.addProject(path: "/code/b")
        let c = ws.addProject(path: "/code/c")
        ws.moveProject(a, onto: c)
        XCTAssertEqual(ws.projects.map(\.id), [b, c, a], "one drag makes a project last")
        ws.moveProject(a, onto: b)
        XCTAssertEqual(ws.projects.map(\.id), [a, b, c], "and first")
        ws.moveProject(a, onto: b)
        XCTAssertEqual(ws.projects.map(\.id), [b, a, c], "neighbours swap")
        ws.moveProject(a, onto: a)
        XCTAssertEqual(ws.projects.map(\.id), [b, a, c])
    }

    // MARK: Sessions

    func testAddSessionToFolderOfDifferentProjectThrows() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        let f = try ws.createFolder(in: p2, named: "F")
        XCTAssertThrowsError(try ws.addSession(makeSession("s", project: p1), toFolder: f)) { error in
            XCTAssertEqual(error as? WorkspaceError, .folderNotInProject)
        }
    }

    func testAddSessionForUnknownProjectThrows() {
        var ws = Workspace()
        XCTAssertThrowsError(try ws.addSession(makeSession("s", project: UUID()))) { error in
            XCTAssertEqual(error as? WorkspaceError, .projectNotFound)
        }
    }

    func testMoveSessionBetweenFoldersAndToUnfiled() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let f1 = try ws.createFolder(in: p, named: "One")
        let f2 = try ws.createFolder(in: p, named: "Two")
        let s = makeSession("s", project: p)
        try ws.addSession(s, toFolder: f1)

        try ws.moveSession(s.id, to: .folder(f2))
        XCTAssertEqual(ws.group(of: s.id), .folder(f2))
        XCTAssertEqual(ws.folder(f1)?.sessionIDs, [])

        try ws.moveSession(s.id, to: .unfiled(projectID: p))
        XCTAssertEqual(ws.group(of: s.id), .unfiled(projectID: p))
        XCTAssertEqual(ws.folder(f2)?.sessionIDs, [])
    }

    func testMoveSessionAtIndexReordersWithinFolder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let f = try ws.createFolder(in: p, named: "F")
        let a = makeSession("a", project: p), b = makeSession("b", project: p), c = makeSession("c", project: p)
        for s in [a, b, c] { try ws.addSession(s, toFolder: f) }
        try ws.moveSession(c.id, to: .folder(f), at: 0)
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [c.id, a.id, b.id])
    }

    func testMoveSessionToFolderInAnotherProjectUpdatesProject() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        let f = try ws.createFolder(in: p2, named: "F")
        let s = makeSession("s", project: p1)
        try ws.addSession(s)
        try ws.moveSession(s.id, to: .folder(f))
        XCTAssertEqual(ws.session(s.id)?.projectID, p2)
    }

    func testCreateFolderFromDroppedSession() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let s = makeSession("s", project: p)
        try ws.addSession(s)
        let f = try ws.createFolder(in: p, named: "Dropped", containing: s.id)
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [s.id])
        XCTAssertEqual(ws.group(of: s.id), .folder(f))
    }

    func testSessionsInGroupExcludeArchivedAndUnfiledSortNewestFirst() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let old = makeSession("old", project: p, activity: 10)
        let new = makeSession("new", project: p, activity: 500)
        var archived = makeSession("archived", project: p, activity: 900)
        archived.isArchived = true
        for s in [old, new, archived] { try ws.addSession(s) }
        XCTAssertEqual(ws.sessions(in: .unfiled(projectID: p)).map(\.name), ["new", "old"])
    }

    func testArchiveCompletedOnlyArchivesCompletedSessions() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let f = try ws.createFolder(in: p, named: "F")
        let done = makeSession("done", project: p, status: .completed)
        let busy = makeSession("busy", project: p, status: .working)
        try ws.addSession(done, toFolder: f)
        try ws.addSession(busy, toFolder: f)
        XCTAssertEqual(ws.archiveCompleted(in: .folder(f)), 1)
        XCTAssertEqual(ws.sessions(in: .folder(f)).map(\.name), ["busy"])
        XCTAssertTrue(ws.session(done.id)!.isArchived)
    }

    func testRemoveSessionRemovesFromFolder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let f = try ws.createFolder(in: p, named: "F")
        let s = makeSession("s", project: p)
        try ws.addSession(s, toFolder: f)
        ws.removeSession(s.id)
        XCTAssertNil(ws.session(s.id))
        XCTAssertEqual(ws.folder(f)?.sessionIDs, [])
    }

    func testRenameSessionRejectsBlank() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let s = makeSession("s", project: p)
        try ws.addSession(s)
        try ws.renameSession(s.id, to: " pr review inline 1427 ")
        XCTAssertEqual(ws.session(s.id)?.name, "pr review inline 1427")
        XCTAssertThrowsError(try ws.renameSession(s.id, to: ""))
    }

    func testStatusCountsIgnoreArchivedAndCanScopeToProject() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        try ws.addSession(makeSession("w", project: p1, status: .working))
        try ws.addSession(makeSession("i", project: p2, status: .awaitingInput))
        try ws.addSession(makeSession("c1", project: p1, status: .completed))
        var archived = makeSession("c2", project: p1, status: .completed)
        archived.isArchived = true
        try ws.addSession(archived)

        XCTAssertEqual(ws.statusCounts(), StatusCounts(working: 1, awaitingInput: 1, completed: 1))
        XCTAssertEqual(ws.statusCounts(projectID: p1), StatusCounts(working: 1, awaitingInput: 0, completed: 1))
    }

    func testSessionLookupByClaudeSessionID() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        var s = makeSession("s", project: p)
        s.claudeSessionID = "abc"
        try ws.addSession(s)
        XCTAssertEqual(ws.session(claudeSessionID: "abc")?.id, s.id)
        XCTAssertNil(ws.session(claudeSessionID: "zzz"))
    }

    func testGroupNameForFolderAndUnfiled() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let f = try ws.createFolder(in: p, named: "Docs site refresh")
        XCTAssertEqual(ws.name(of: .folder(f)), "Docs site refresh")
        XCTAssertEqual(ws.name(of: .unfiled(projectID: p)), "Unfiled")
    }

    func testToggleProjectCollapsed() {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        XCTAssertFalse(ws.project(p)!.isCollapsed)
        ws.toggleCollapsed(p)
        XCTAssertTrue(ws.project(p)!.isCollapsed)
    }

    // MARK: Codable

    func testWorkspaceRoundTripsThroughJSON() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let f = try ws.createFolder(in: p, named: "F")
        var s = makeSession("s", project: p, status: .awaitingInput)
        s.pullRequestURLs = ["https://github.com/o/r/pull/1"]
        try ws.addSession(s, toFolder: f)

        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, ws)
    }
}
