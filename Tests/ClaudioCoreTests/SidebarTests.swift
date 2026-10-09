import XCTest
@testable import ClaudioCore

final class SidebarTests: XCTestCase {
    private var ws = Workspace()
    private var ds = UUID(), dw = UUID()
    private var storageFolder = UUID(), emptyFolder = UUID()
    private let home = "/Users/tim"

    override func setUpWithError() throws {
        ws = Workspace()
        ds = ws.addProject(path: "/Users/tim/Documents/Code/DigiScript")
        dw = ws.addProject(path: "/Users/tim/Code/dreamteam-web")
        storageFolder = try ws.createFolder(in: ds, named: "Storage fix — PR #1427")
        emptyFolder = try ws.createFolder(in: ds, named: "Mic planner perf")
        try ws.addSession(Session(projectID: ds, name: "investigate issue correlation", workingDirectory: "/", status: .working,
                                  summary: "2 agents in flight"), toFolder: storageFolder)
        try ws.addSession(Session(projectID: ds, name: "pr review inline 1427", workingDirectory: "/"), toFolder: storageFolder)
        try ws.addSession(Session(projectID: ds, name: "pdf script handling", workingDirectory: "/", summary: "Options paper for PDF import"))
        try ws.addSession(Session(projectID: dw, name: "migrate docs to vitepress", workingDirectory: "/", status: .awaitingInput))
    }

    func testUnfilteredTreeShowsAllFoldersWithUnfiledLast() {
        let tree = Sidebar.build(ws, filter: "", home: home)
        XCTAssertEqual(tree.map(\.name), ["DigiScript", "dreamteam-web"])
        XCTAssertEqual(tree[0].displayPath, "~/…/DigiScript")
        XCTAssertEqual(tree[0].folders.map(\.name), ["Storage fix — PR #1427", "Mic planner perf", "Unfiled"])
        XCTAssertEqual(tree[0].folders.map(\.isUnfiled), [false, false, true])
        XCTAssertEqual(tree[0].folders[0].sessions.map(\.name), ["investigate issue correlation", "pr review inline 1427"])
        XCTAssertEqual(tree[0].folders[2].group, .unfiled(projectID: ds))
        // dreamteam-web has no folders, only Unfiled.
        XCTAssertEqual(tree[1].folders.map(\.name), ["Unfiled"])
    }

    func testCollapsedProjectHidesFoldersUnlessFiltering() {
        ws.toggleCollapsed(ds)
        XCTAssertTrue(Sidebar.build(ws, filter: "", home: home)[0].folders.isEmpty)
        XCTAssertTrue(Sidebar.build(ws, filter: "", home: home)[0].isCollapsed)
        XCTAssertFalse(Sidebar.build(ws, filter: "pdf", home: home)[0].folders.isEmpty)
    }

    func testFilterMatchesSessionNamesAndSummariesCaseInsensitively() {
        let tree = Sidebar.build(ws, filter: "OPTIONS paper", home: home)
        XCTAssertEqual(tree.map(\.name), ["DigiScript"])
        XCTAssertEqual(tree[0].folders.map(\.name), ["Unfiled"])
        XCTAssertEqual(tree[0].folders[0].sessions.map(\.name), ["pdf script handling"])
    }

    func testFilterMatchingFolderNameShowsWholeFolder() {
        let tree = Sidebar.build(ws, filter: "1427", home: home)
        XCTAssertEqual(tree[0].folders.map(\.name), ["Storage fix — PR #1427"])
        XCTAssertEqual(tree[0].folders[0].sessions.count, 2)

        let empty = Sidebar.build(ws, filter: "mic planner", home: home)
        XCTAssertEqual(empty[0].folders.map(\.name), ["Mic planner perf"])
    }

    func testFilterMatchingProjectNameShowsWholeProject() {
        let tree = Sidebar.build(ws, filter: "dreamteam", home: home)
        XCTAssertEqual(tree.map(\.name), ["dreamteam-web"])
        XCTAssertEqual(tree[0].folders.first?.sessions.count, 1)
    }

    func testNoMatchesYieldsEmptyTree() {
        XCTAssertTrue(Sidebar.build(ws, filter: "zzz", home: home).isEmpty)
    }

    func testFolderCountsExcludeArchived() throws {
        let id = ws.sessions(in: .folder(storageFolder)).last!.id
        ws.updateSession(id) { $0.isArchived = true }
        let tree = Sidebar.build(ws, filter: "", home: home)
        XCTAssertEqual(tree[0].folders[0].sessions.count, 1)
    }

    func testProjectBadgeCountsActiveSessionsAndFlagsInput() {
        let tree = Sidebar.build(ws, filter: "", home: home)
        XCTAssertEqual(tree[0].activeCount, 1)
        XCTAssertFalse(tree[0].hasAwaitingInput)
        XCTAssertEqual(tree[1].activeCount, 1)
        XCTAssertTrue(tree[1].hasAwaitingInput)
        XCTAssertEqual(tree[1].initials, "DW")
    }

    // MARK: Nested folders

    func testNestedFoldersFlattenInPreOrderWithDepth() throws {
        let child = try ws.createFolder(in: ds, named: "Child", parentID: storageFolder)
        try ws.createFolder(in: ds, named: "Grandchild", parentID: child)
        let tree = Sidebar.build(ws, filter: "", home: home)
        let names = tree[0].folders.map(\.name)
        XCTAssertEqual(names, ["Storage fix — PR #1427", "Child", "Grandchild", "Mic planner perf", "Unfiled"])
        XCTAssertEqual(tree[0].folders.map(\.depth), [0, 1, 2, 0, 0])
    }

    func testCollapsedFolderHidesItsSubfoldersUnlessFiltering() throws {
        let child = try ws.createFolder(in: ds, named: "Child", parentID: storageFolder)
        try ws.addSession(Session(projectID: ds, name: "nested session", workingDirectory: "/"), toFolder: child)
        ws.toggleCollapsed(.folder(storageFolder))

        let collapsed = Sidebar.build(ws, filter: "", home: home)
        XCTAssertFalse(collapsed[0].folders.contains { $0.name == "Child" }, "collapsed parent hides its subtree")

        let filtered = Sidebar.build(ws, filter: "nested session", home: home)
        XCTAssertTrue(filtered[0].folders.contains { $0.name == "Child" }, "filtering overrides collapse")
    }

    func testFolderPillAndCountRollUpTheWholeSubtree() throws {
        let child = try ws.createFolder(in: ds, named: "Child", parentID: storageFolder)
        try ws.addSession(Session(projectID: ds, name: "nested working", workingDirectory: "/", status: .working), toFolder: child)
        let tree = Sidebar.build(ws, filter: "", home: home)
        let parent = try XCTUnwrap(tree[0].folders.first { $0.name == "Storage fix — PR #1427" })
        // Its own 2 direct sessions plus the child's 1 nested one.
        XCTAssertEqual(parent.sessionCount, 3)
        // One of its direct sessions is already Working (set up above); the
        // nested one adds a second.
        XCTAssertEqual(parent.statusCounts.working, 2)
        XCTAssertEqual(parent.sessions.count, 2, "its row itself still lists only its direct sessions")
    }

    func testProjectHeaderCountDoesNotDoubleCountNestedSubtrees() throws {
        let child = try ws.createFolder(in: ds, named: "Child", parentID: storageFolder)
        try ws.addSession(Session(projectID: ds, name: "nested", workingDirectory: "/"), toFolder: child)
        let tree = Sidebar.build(ws, filter: "", home: home)
        // 2 in storageFolder + 1 nested + 1 in Unfiled, each counted once.
        XCTAssertEqual(tree[0].statusCounts.total, 4)
    }

    func testFilterMatchingDescendantFolderNameShowsItsAncestors() throws {
        try ws.createFolder(in: ds, named: "Deeply Nested Match", parentID: emptyFolder)
        let tree = Sidebar.build(ws, filter: "deeply nested", home: home)
        XCTAssertEqual(tree[0].folders.map(\.name), ["Mic planner perf", "Deeply Nested Match"])
    }

    func testFilterKeepsAncestorsOfASurvivingDeepDescendant() throws {
        // A (aged-out session) > B (aged-out session) > C (a Working
        // session, which always counts as recent regardless of its date).
        let old = Date(timeIntervalSince1970: 0)
        let a = try ws.createFolder(in: ds, named: "A")
        let b = try ws.createFolder(in: ds, named: "B", parentID: a)
        let c = try ws.createFolder(in: ds, named: "C", parentID: b)
        try ws.addSession(Session(projectID: ds, name: "old in A", workingDirectory: "/", createdAt: old, lastActivity: old), toFolder: a)
        try ws.addSession(Session(projectID: ds, name: "old in B", workingDirectory: "/", createdAt: old, lastActivity: old), toFolder: b)
        try ws.addSession(Session(projectID: ds, name: "live in C", workingDirectory: "/", status: .working), toFolder: c)

        let tree = Sidebar.build(ws, filter: "", activeSince: Date(timeIntervalSince1970: 1), home: home)
        let names = try XCTUnwrap(tree.first { $0.name == "DigiScript" }).folders.map(\.name)
        XCTAssertTrue(names.contains("A") && names.contains("B") && names.contains("C"),
                      "A and B still show, with none of their own sessions, so C stays reachable")
        let folderB = try XCTUnwrap(tree.first { $0.name == "DigiScript" }?.folders.first { $0.name == "B" })
        XCTAssertEqual(folderB.sessions, [], "B's own aged-out session is filtered from its row")
        XCTAssertEqual(folderB.sessionCount, 1, "but its pill still counts C's live session")
    }
}
