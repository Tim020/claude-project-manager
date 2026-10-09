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

    // MARK: Nested folders

    func testCreateSubfolderNestsAndScopesUniqueNamesToSiblings() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Parent")
        let child = try ws.createFolder(in: p, named: "", parentID: parent)
        XCTAssertEqual(ws.folder(child)?.parentID, parent)
        XCTAssertEqual(ws.folder(child)?.name, "New Folder", "unique among its siblings, and it has none yet")
        let sibling = try ws.createFolder(in: p, named: "", parentID: parent)
        XCTAssertEqual(ws.folder(sibling)?.name, "New Folder 2")
        // A top-level folder can reuse "New Folder" since it's a different sibling group.
        let topLevel = try ws.createFolder(in: p, named: "")
        XCTAssertEqual(ws.folder(topLevel)?.name, "New Folder")
    }

    func testCreateSubfolderInAnotherProjectsFolderThrows() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        let parent = try ws.createFolder(in: p1, named: "Parent")
        XCTAssertThrowsError(try ws.createFolder(in: p2, named: "Child", parentID: parent)) { error in
            XCTAssertEqual(error as? WorkspaceError, .folderNotInProject)
        }
    }

    func testMoveFolderIntoFolderNestsAsLastChild() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Parent")
        let other = try ws.createFolder(in: p, named: "Other")
        try ws.moveFolder(other, intoFolder: parent)
        XCTAssertEqual(ws.folder(other)?.parentID, parent)
        XCTAssertEqual(ws.foldersInDisplayOrder(projectID: p).map(\.folder.name), ["Parent", "Other"])
        XCTAssertEqual(ws.foldersInDisplayOrder(projectID: p).map(\.depth), [0, 1])
    }

    func testMoveFolderIntoItselfOrItsOwnDescendantThrows() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Parent")
        let child = try ws.createFolder(in: p, named: "Child", parentID: parent)
        XCTAssertThrowsError(try ws.moveFolder(parent, intoFolder: child)) { error in
            XCTAssertEqual(error as? WorkspaceError, .cyclicFolderMove)
        }
        XCTAssertThrowsError(try ws.moveFolder(parent, intoFolder: parent)) { error in
            XCTAssertEqual(error as? WorkspaceError, .cyclicFolderMove, "into itself")
        }
    }

    /// The `before`/`after` sibling-placement path reparents the same way
    /// `intoFolder` does, so it's just as able to create a cycle, and goes
    /// through the very same guard.
    func testMoveFolderBeforeOrAfterADescendantThrows() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let grandparent = try ws.createFolder(in: p, named: "Grandparent")
        let parent = try ws.createFolder(in: p, named: "Parent", parentID: grandparent)
        let child = try ws.createFolder(in: p, named: "Child", parentID: parent)
        XCTAssertThrowsError(try ws.moveFolder(grandparent, before: child, inProject: p)) { error in
            XCTAssertEqual(error as? WorkspaceError, .cyclicFolderMove)
        }
        XCTAssertThrowsError(try ws.moveFolder(grandparent, after: child, inProject: p)) { error in
            XCTAssertEqual(error as? WorkspaceError, .cyclicFolderMove)
        }
    }

    func testMoveFolderAfterPutsItRightAfterItsNewSibling() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let a = try ws.createFolder(in: p, named: "A")
        try ws.createFolder(in: p, named: "B")
        let c = try ws.createFolder(in: p, named: "C")
        try ws.moveFolder(c, after: a, inProject: p)
        XCTAssertEqual(ws.project(p)!.folders.map(\.name), ["A", "C", "B"])
    }

    func testMoveFolderIntoCarriesItsWholeSubtreeAndSessionsToAnotherProject() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        let parent = try ws.createFolder(in: p1, named: "Parent")
        let child = try ws.createFolder(in: p1, named: "Child", parentID: parent)
        let destination = try ws.createFolder(in: p2, named: "Destination")
        let s = makeSession("s", project: p1)
        try ws.addSession(s, toFolder: child)
        try ws.moveFolder(parent, intoFolder: destination)
        XCTAssertEqual(ws.projectID(containingFolder: parent), p2)
        XCTAssertEqual(ws.projectID(containingFolder: child), p2)
        XCTAssertEqual(ws.folder(parent)?.parentID, destination)
        XCTAssertEqual(ws.folder(child)?.parentID, parent, "its own nesting under parent is unaffected")
        XCTAssertEqual(ws.session(s.id)?.projectID, p2)
        XCTAssertTrue(ws.project(p1)!.folders.isEmpty)
    }

    func testMoveFolderToProjectCarriesAMultiLevelBranchingSubtree() throws {
        var ws = Workspace()
        let p1 = ws.addProject(path: "/code/a")
        let p2 = ws.addProject(path: "/code/b")
        let root = try ws.createFolder(in: p1, named: "Root")
        let childA = try ws.createFolder(in: p1, named: "ChildA", parentID: root)
        let childB = try ws.createFolder(in: p1, named: "ChildB", parentID: root)
        let grandchild = try ws.createFolder(in: p1, named: "Grandchild", parentID: childA)
        let inRoot = makeSession("in root", project: p1)
        let inChildB = makeSession("in child B", project: p1)
        let inGrandchild = makeSession("in grandchild", project: p1)
        try ws.addSession(inRoot, toFolder: root)
        try ws.addSession(inChildB, toFolder: childB)
        try ws.addSession(inGrandchild, toFolder: grandchild)
        let untouched = try ws.createFolder(in: p1, named: "Untouched")

        try ws.moveFolder(root, toProject: p2)

        XCTAssertEqual(Set(ws.project(p2)!.folders.map(\.id)), [root, childA, childB, grandchild], "the whole subtree moved")
        XCTAssertEqual(ws.project(p1)!.folders.map(\.id), [untouched], "only the unrelated folder stays behind")
        XCTAssertNil(ws.folder(root)?.parentID)
        XCTAssertEqual(ws.folder(childA)?.parentID, root)
        XCTAssertEqual(ws.folder(childB)?.parentID, root)
        XCTAssertEqual(ws.folder(grandchild)?.parentID, childA, "nesting within the moved subtree is unaffected")
        for session in [inRoot, inChildB, inGrandchild] {
            XCTAssertEqual(ws.session(session.id)?.projectID, p2, "\(session.name) re-homed")
        }
    }

    func testMoveFolderBeforeAndAfterAtDepthKeepsTheSharedParent() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Parent")
        let a = try ws.createFolder(in: p, named: "A", parentID: parent)
        let b = try ws.createFolder(in: p, named: "B", parentID: parent)
        let c = try ws.createFolder(in: p, named: "C", parentID: parent)
        try ws.createFolder(in: p, named: "Outsider")

        try ws.moveFolder(c, before: a, inProject: p)
        XCTAssertEqual(ws.foldersInDisplayOrder(projectID: p).filter { $0.folder.parentID == parent }.map(\.folder.name), ["C", "A", "B"])
        XCTAssertEqual(ws.folder(c)?.parentID, parent, "reordering among nested siblings keeps their shared parent")

        try ws.moveFolder(a, after: b, inProject: p)
        XCTAssertEqual(ws.foldersInDisplayOrder(projectID: p).filter { $0.folder.parentID == parent }.map(\.folder.name), ["C", "B", "A"])
        XCTAssertEqual(ws.folder(a)?.parentID, parent)
    }

    func testDeleteFolderPromotesChildrenToItsParent() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let grandparent = try ws.createFolder(in: p, named: "Grandparent")
        let parent = try ws.createFolder(in: p, named: "Parent", parentID: grandparent)
        let child = try ws.createFolder(in: p, named: "Child", parentID: parent)
        let direct = makeSession("direct", project: p)
        try ws.addSession(direct, toFolder: parent)
        ws.deleteFolder(parent)
        XCTAssertNil(ws.folder(parent))
        XCTAssertEqual(ws.folder(child)?.parentID, grandparent, "promoted up one level")
        XCTAssertEqual(ws.group(of: direct.id), .folder(grandparent), "its direct sessions move up too")
    }

    func testDeleteTopLevelFolderPromotesChildrenToTopLevelAndSessionsToUnfiled() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Parent")
        let child = try ws.createFolder(in: p, named: "Child", parentID: parent)
        let s = makeSession("s", project: p)
        try ws.addSession(s, toFolder: parent)
        ws.deleteFolder(parent)
        XCTAssertNil(ws.folder(child)?.parentID)
        XCTAssertEqual(ws.group(of: s.id), .unfiled(projectID: p))
    }

    func testDeleteFolderFlattenToUnfiledRemovesWholeSubtree() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Parent")
        let child = try ws.createFolder(in: p, named: "Child", parentID: parent)
        let direct = makeSession("direct", project: p)
        let nested = makeSession("nested", project: p)
        try ws.addSession(direct, toFolder: parent)
        try ws.addSession(nested, toFolder: child)
        ws.deleteFolder(parent, mode: .flattenToUnfiled)
        XCTAssertNil(ws.folder(parent))
        XCTAssertNil(ws.folder(child))
        XCTAssertEqual(ws.group(of: direct.id), .unfiled(projectID: p))
        XCTAssertEqual(ws.group(of: nested.id), .unfiled(projectID: p))
    }

    func testDeleteFolderFlattenToUnfiledClosesEveryOverviewTabInTheSubtree() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Parent")
        let child = try ws.createFolder(in: p, named: "Child", parentID: parent)
        let grandchild = try ws.createFolder(in: p, named: "Grandchild", parentID: child)
        let parentTab = try XCTUnwrap(ws.openOverview(.folder(.folder(parent))))
        let childTab = try XCTUnwrap(ws.openOverview(.folder(.folder(child))))
        let grandchildTab = try XCTUnwrap(ws.openOverview(.folder(.folder(grandchild))))
        XCTAssertEqual(Set(ws.openTabIDs), [parentTab, childTab, grandchildTab])

        ws.deleteFolder(parent, mode: .flattenToUnfiled)

        XCTAssertTrue(ws.overviewTabs.isEmpty)
        XCTAssertTrue(ws.openTabIDs.isEmpty)
    }

    func testSubtreeFolderIDsAndSessionsInSubtreeCoverEveryDepth() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let grandparent = try ws.createFolder(in: p, named: "Grandparent")
        let parent = try ws.createFolder(in: p, named: "Parent", parentID: grandparent)
        let child = try ws.createFolder(in: p, named: "Child", parentID: parent)
        let direct = makeSession("direct", project: p)
        let nested = makeSession("nested", project: p)
        try ws.addSession(direct, toFolder: grandparent)
        try ws.addSession(nested, toFolder: child)
        XCTAssertEqual(ws.subtreeFolderIDs(of: grandparent), [grandparent, parent, child])
        XCTAssertEqual(Set(ws.sessionsInSubtree(.folder(grandparent)).map(\.name)), ["direct", "nested"])
        XCTAssertEqual(ws.sessionsInSubtree(.folder(child)).map(\.name), ["nested"])
        XCTAssertTrue(ws.isFolder(child, orDescendantOf: grandparent))
        XCTAssertFalse(ws.isFolder(grandparent, orDescendantOf: child))
    }

    /// "Nest without limit" is the feature's whole premise, so exercise it
    /// past the 2-3 levels every other test uses: 20 deep.
    func testNestingHasNoDepthLimit() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        var ids: [UUID] = []
        var parentID: UUID?
        for depth in 0..<20 {
            let id = try ws.createFolder(in: p, named: "L\(depth)", parentID: parentID)
            ids.append(id)
            parentID = id
        }
        let deepest = ids.last!
        let s = makeSession("deepest", project: p)
        try ws.addSession(s, toFolder: deepest)

        XCTAssertEqual(ws.subtreeFolderIDs(of: ids[0]).count, 20, "every level is in the root's subtree")
        XCTAssertEqual(ws.sessionsInSubtree(.folder(ids[0])).map(\.name), ["deepest"])
        XCTAssertEqual(ws.path(of: .folder(deepest)), (0..<20).map { "L\($0)" }.joined(separator: " › "))
        XCTAssertEqual(ws.foldersInDisplayOrder(projectID: p).map(\.depth), Array(0..<20))
        XCTAssertTrue(ws.isFolder(deepest, orDescendantOf: ids[0]))

        // The deepest folder can still be relocated, and still carries its
        // one session, like at any other depth.
        let other = try ws.createFolder(in: p, named: "Other")
        try ws.moveFolder(deepest, intoFolder: other)
        XCTAssertEqual(ws.folder(deepest)?.parentID, other)
        XCTAssertEqual(ws.group(of: s.id), .folder(deepest))
    }

    func testPathJoinsAncestorNamesOutermostFirst() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let parent = try ws.createFolder(in: p, named: "Backend")
        let child = try ws.createFolder(in: p, named: "Auth", parentID: parent)
        XCTAssertEqual(ws.path(of: .folder(child)), "Backend › Auth")
        XCTAssertEqual(ws.path(of: .folder(parent)), "Backend")
        XCTAssertEqual(ws.path(of: .unfiled(projectID: p)), "Unfiled")
        XCTAssertEqual(ws.folderAndAncestorNames(of: child), ["Auth", "Backend"], "innermost first")
    }

    func testCorruptedParentIDsAreSanitizedOnDecode() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let a = try ws.createFolder(in: p, named: "A")
        let b = try ws.createFolder(in: p, named: "B", parentID: a)
        // Form a cycle by hand, as a corrupted state.json might, then round-trip.
        ws.setParentIDForTesting(a, to: b)
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertNil(decoded.folder(a)?.parentID, "the cycle is broken")
        XCTAssertEqual(decoded.folder(b)?.parentID, a, "the rest of the (now acyclic) chain is kept")
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

    func testArchiveCompletedInAProjectCoversItsFoldersAndUnfiled() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/a")
        let other = ws.addProject(path: "/code/b")
        let f = try ws.createFolder(in: p, named: "F")
        let filed = makeSession("filed", project: p, status: .completed)
        let unfiled = makeSession("unfiled", project: p, status: .completed)
        let busy = makeSession("busy", project: p, status: .working)
        let elsewhere = makeSession("elsewhere", project: other, status: .completed)
        try ws.addSession(filed, toFolder: f)
        try ws.addSession(busy, toFolder: f)
        try ws.addSession(unfiled)
        try ws.addSession(elsewhere)
        XCTAssertEqual(Set(ws.archiveCompleted(inProject: p)), [filed.id, unfiled.id])
        XCTAssertEqual(ws.sessions(in: .folder(f)).map(\.name), ["busy"])
        XCTAssertTrue(ws.sessions(in: .unfiled(projectID: p)).isEmpty)
        XCTAssertFalse(ws.session(elsewhere.id)!.isArchived, "other projects are left alone")
        XCTAssertEqual(ws.archiveCompleted(inProject: p), [], "already archived")
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
        s.pullRequests = [PullRequestLink("https://github.com/o/r/pull/1", .opened), PullRequestLink("#2", .reviewed)]
        try ws.addSession(s, toFolder: f)

        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, ws)
    }
}
