import XCTest
@testable import ClaudioCore

final class PaneLayoutTests: XCTestCase {
    let ids = (0..<6).map { _ in UUID() }

    private func layout(_ count: Int) -> PaneLayout {
        var layout = PaneLayout()
        layout.reconcile(openTabIDs: Array(ids.prefix(count)))
        return layout
    }

    /// The tree as nested arrays of tab lists, e.g. "H[V[[0],[1]],[2]]".
    private func shape(_ node: PaneNode) -> String {
        switch node {
        case .group(let group):
            return "[" + group.tabIDs.compactMap { id in ids.firstIndex(of: id).map(String.init) }.joined(separator: ",") + "]"
        case .split(let split):
            return (split.axis == .horizontal ? "H" : "V") + "[" + split.children.map(shape).joined(separator: ",") + "]"
        }
    }

    func testNewLayoutsAreEqualAndReconcileIsIdempotent() {
        XCTAssertEqual(PaneLayout(), PaneLayout())
        XCTAssertEqual(Workspace(), Workspace())
        var layout = layout(3)
        let once = layout
        layout.reconcile(openTabIDs: Array(ids.prefix(3)))
        XCTAssertEqual(layout, once)
        var empty = PaneLayout()
        empty.reconcile(openTabIDs: [])
        XCTAssertEqual(empty, PaneLayout())
    }

    func testOpenedTabsJoinTheFocusedPane() {
        var layout = layout(2)
        layout.split(ids[1], to: .right, of: layout.focusedGroupID)
        layout.reconcile(openTabIDs: Array(ids.prefix(3)))
        XCTAssertEqual(shape(layout.root), "H[[0],[1,2]]")
        XCTAssertEqual(layout.focusedTabID, ids[1], "opening a tab doesn't show it by itself")
    }

    func testSplitOnEachEdge() {
        for (edge, expected) in [(PaneEdge.left, "H[[1],[0]]"), (.right, "H[[0],[1]]"), (.top, "V[[1],[0]]"), (.bottom, "V[[0],[1]]")] {
            var layout = layout(2)
            layout.split(ids[1], to: edge, of: layout.focusedGroupID)
            XCTAssertEqual(shape(layout.root), expected, "\(edge)")
            XCTAssertEqual(layout.focusedTabID, ids[1], "the moved tab's new pane has focus")
        }
    }

    func testTwoByTwoGrid() throws {
        var layout = layout(4)
        let first = layout.focusedGroupID
        layout.split(ids[1], to: .right, of: first)
        let second = layout.focusedGroupID
        layout.split(ids[2], to: .bottom, of: first)
        layout.split(ids[3], to: .bottom, of: second)
        XCTAssertEqual(shape(layout.root), "H[V[[0],[2]],V[[1],[3]]]")
        guard case .split(let root) = layout.root else { return XCTFail("not split") }
        XCTAssertEqual(root.fractions, [0.5, 0.5])
    }

    func testSplittingBesideASiblingSharesItsSpace() throws {
        var layout = layout(3)
        let first = layout.focusedGroupID
        layout.split(ids[1], to: .right, of: first)
        layout.split(ids[2], to: .right, of: first)
        XCTAssertEqual(shape(layout.root), "H[[0],[2],[1]]", "a third column, not a nested split")
        guard case .split(let root) = layout.root else { return XCTFail("not split") }
        XCTAssertEqual(root.fractions, [0.25, 0.25, 0.5])
    }

    func testMovingTheLastTabOutClosesThePaneAndFlattens() {
        var layout = layout(3)
        let first = layout.focusedGroupID
        layout.split(ids[1], to: .right, of: first)
        let right = layout.focusedGroupID
        layout.split(ids[2], to: .bottom, of: right)
        XCTAssertEqual(shape(layout.root), "H[[0],V[[1],[2]]]")
        // Moving [1] next to [0] leaves the column with one pane, which collapses.
        layout.move(ids[1], toGroup: first)
        XCTAssertEqual(shape(layout.root), "H[[0,1],[2]]")
        XCTAssertEqual(layout.focusedGroupID, first)
        XCTAssertEqual(layout.focusedTabID, ids[1])
    }

    func testNestedSameAxisSplitsMerge() {
        var layout = layout(3)
        let first = layout.focusedGroupID
        layout.split(ids[1], to: .bottom, of: first)
        let bottom = layout.focusedGroupID
        layout.split(ids[2], to: .right, of: bottom)
        XCTAssertEqual(shape(layout.root), "V[[0],H[[1],[2]]]")
        // Closing [0] leaves V[H[…]], which becomes the inner split itself.
        layout.reconcile(openTabIDs: [ids[1], ids[2]])
        XCTAssertEqual(shape(layout.root), "H[[1],[2]]")
    }

    func testFractionsRenormaliseWhenAPaneCloses() {
        var layout = layout(3)
        let first = layout.focusedGroupID
        layout.split(ids[1], to: .right, of: first)
        layout.split(ids[2], to: .right, of: layout.focusedGroupID)
        guard case .split(let before) = layout.root else { return XCTFail("not split") }
        XCTAssertEqual(before.fractions, [0.5, 0.25, 0.25])
        layout.reconcile(openTabIDs: [ids[0], ids[1]])
        guard case .split(let after) = layout.root else { return XCTFail("not split") }
        XCTAssertEqual(after.fractions[0], 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(after.fractions[1], 1.0 / 3, accuracy: 1e-9)
    }

    func testAPanesOnlyTabCantSplitBesideItself() {
        var layout = layout(2)
        layout.split(ids[1], to: .right, of: layout.focusedGroupID)
        let before = layout
        layout.split(ids[1], to: .bottom, of: layout.focusedGroupID)
        XCTAssertEqual(layout, before)
    }

    func testReorderWithinAPane() {
        var layout = layout(3)
        let group = layout.focusedGroupID
        layout.move(ids[0], toGroup: group, at: 3)
        XCTAssertEqual(shape(layout.root), "[1,2,0]")
        layout.move(ids[0], toGroup: group, at: 0)
        XCTAssertEqual(shape(layout.root), "[0,1,2]")
        layout.move(ids[2], toGroup: group, at: 1)
        XCTAssertEqual(shape(layout.root), "[0,2,1]")
    }

    func testClosingTheShownTabShowsItsLeftNeighbour() {
        var layout = layout(3)
        layout.select(ids[1])
        layout.reconcile(openTabIDs: [ids[0], ids[2]])
        XCTAssertEqual(layout.focusedTabID, ids[0])
        layout.reconcile(openTabIDs: [ids[2]])
        XCTAssertEqual(layout.focusedTabID, ids[2])
    }

    func testResizeNormalises() {
        var layout = layout(2)
        layout.split(ids[1], to: .right, of: layout.focusedGroupID)
        let splitID = layout.root.id
        layout.resize(splitID, fractions: [3, 1])
        guard case .split(let split) = layout.root else { return XCTFail("not split") }
        XCTAssertEqual(split.fractions, [0.75, 0.25])
        layout.resize(splitID, fractions: [1])
        guard case .split(let reset) = layout.root else { return XCTFail("not split") }
        XCTAssertEqual(reset.fractions, [0.5, 0.5], "a mismatched list falls back to equal shares")
    }

    func testDropZones() {
        XCTAssertEqual(PaneDropZone.zone(x: 500, y: 400, width: 1000, height: 800), .center)
        XCTAssertEqual(PaneDropZone.zone(x: 50, y: 400, width: 1000, height: 800), .edge(.left))
        XCTAssertEqual(PaneDropZone.zone(x: 950, y: 400, width: 1000, height: 800), .edge(.right))
        XCTAssertEqual(PaneDropZone.zone(x: 500, y: 30, width: 1000, height: 800), .edge(.top))
        XCTAssertEqual(PaneDropZone.zone(x: 500, y: 780, width: 1000, height: 800), .edge(.bottom))
        XCTAssertEqual(PaneDropZone.zone(x: 50, y: 400, width: 1000, height: 800, canSplit: false), .center)
        XCTAssertEqual(PaneDropZone.zone(x: 20, y: 100, width: 500, height: 800), .edge(.top),
                       "too narrow to halve sideways, so the nearest edge that fits")
        XCTAssertEqual(PaneDropZone.zone(x: 20, y: 150, width: 500, height: 300), .center, "too small to halve either way")
    }

    func testDragPayload() {
        let id = ids[0]
        XCTAssertEqual(TabDragPayload.sessionID(from: TabDragPayload.string(for: id)), id)
        XCTAssertEqual(TabDragPayload.sessionID(from: id.uuidString), id, "sessions dragged from the sidebar")
        XCTAssertNil(UUID(uuidString: TabDragPayload.string(for: id)), "the sidebar ignores dragged tabs")
        XCTAssertNil(TabDragPayload.sessionID(from: "hello"))
    }
}

final class WorkspacePaneTests: XCTestCase {
    private func workspace(_ count: Int) throws -> (Workspace, [UUID]) {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        var ids: [UUID] = []
        for n in 0..<count {
            let s = Session(projectID: p, name: "s\(n)", workingDirectory: "/code")
            try ws.addSession(s)
            ws.openTab(s.id)
            ids.append(s.id)
        }
        return (ws, ids)
    }

    func testRemovingSessionsAndProjectsPrunesPanes() throws {
        var (ws, ids) = try workspace(3)
        ws.splitTab(ids[1], to: .right, of: ws.panes.focusedGroupID)
        ws.splitTab(ids[2], to: .bottom, of: ws.panes.focusedGroupID)
        XCTAssertEqual(ws.panes.groups.count, 3)
        ws.removeSession(ids[2])
        XCTAssertEqual(ws.panes.groups.map(\.tabIDs), [[ids[0]], [ids[1]]])
        ws.removeProject(ws.projects[0].id)
        XCTAssertEqual(ws.panes.groups.map(\.tabIDs), [[]])
        XCTAssertNil(ws.panes.focusedTabID)
    }

    func testCloseCompletedAndTabsToTheSideStayInTheirPane() throws {
        var (ws, ids) = try workspace(4)
        ws.splitTab(ids[3], to: .right, of: ws.panes.focusedGroupID)
        XCTAssertEqual(ws.tabIDs(rightOf: ids[0]), [ids[1], ids[2]], "only the tab's own pane")
        XCTAssertEqual(ws.tabIDs(leftOf: ids[3]), [])
        ws.closeOtherTabs(keeping: ids[1])
        XCTAssertEqual(ws.panes.groups.map(\.tabIDs), [[ids[1]], [ids[3]]])
        ws.closeCompletedTabs()
        XCTAssertEqual(ws.panes.groups.map(\.tabIDs), [[]], "new sessions are completed")
    }

    func testSplittingAClosedSessionOpensIt() throws {
        var (ws, ids) = try workspace(2)
        ws.closeTab(ids[1])
        ws.splitTab(ids[1], to: .top, of: ws.panes.focusedGroupID)
        XCTAssertTrue(ws.isOpen(ids[1]))
        XCTAssertEqual(ws.panes.groups.map(\.tabIDs), [[ids[1]], [ids[0]]])
    }

    func testLayoutRoundTripsAndOldFilesStartWithOnePane() throws {
        var (ws, ids) = try workspace(3)
        ws.splitTab(ids[2], to: .bottom, of: ws.panes.focusedGroupID)
        let data = try JSONFileStore.encoder.encode(ws)
        XCTAssertEqual(try JSONFileStore.decoder.decode(Workspace.self, from: data).panes, ws.panes)

        let old = #"{"projects":[],"sessions":[],"openSessionIDs":["\#(ids[0].uuidString)","\#(ids[1].uuidString)"]}"#
        let decoded = try JSONFileStore.decoder.decode(Workspace.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.panes.groups.map(\.tabIDs), [[ids[0], ids[1]]])
        XCTAssertEqual(decoded.panes.focusedTabID, ids[0])

        let broken = #"{"projects":[],"sessions":[],"openSessionIDs":[],"panes":{"root":42}}"#
        XCTAssertEqual(try JSONFileStore.decoder.decode(Workspace.self, from: Data(broken.utf8)).panes, PaneLayout(),
                       "a layout that doesn't decode starts again")
    }

    func testStaleTabsInASavedLayoutAreDropped() throws {
        var (ws, ids) = try workspace(2)
        ws.splitTab(ids[1], to: .right, of: ws.panes.focusedGroupID)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONFileStore.encoder.encode(ws)) as? [String: Any])
        json["openSessionIDs"] = [ids[0].uuidString]
        let decoded = try JSONFileStore.decoder.decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.panes.groups.map(\.tabIDs), [[ids[0]]])
    }
}
