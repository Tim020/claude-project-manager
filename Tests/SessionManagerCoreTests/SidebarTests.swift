import XCTest
@testable import SessionManagerCore

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
}
