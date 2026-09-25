import XCTest
@testable import ClaudioCore

final class RecencyFilterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_352_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func workspace() throws -> (Workspace, [String: UUID]) {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let recentFolder = try ws.createFolder(in: p, named: "Recent")
        let oldFolder = try ws.createFolder(in: p, named: "Old")
        _ = try ws.createFolder(in: p, named: "Empty")
        var ids: [String: UUID] = [:]
        func add(_ name: String, _ age: Double, _ status: SessionStatus = .completed, folder: UUID?) throws {
            let s = Session(projectID: p, name: name, workingDirectory: "/code", status: status,
                            createdAt: daysAgo(age), lastActivity: daysAgo(age))
            try ws.addSession(s, toFolder: folder)
            ids[name] = s.id
        }
        try add("fresh", 1, folder: recentFolder)
        try add("stale", 20, folder: recentFolder)
        try add("ancient", 60, folder: oldFolder)
        try add("old but waiting", 40, .awaitingInput, folder: nil)
        try add("old unfiled", 30, folder: nil)
        return (ws, ids)
    }

    private func names(_ tree: [SidebarProject]) -> [String] {
        tree.flatMap { $0.folders.flatMap { $0.sessions.map(\.name) } }
    }

    func testWithoutAWindowEverythingShows() throws {
        let (ws, _) = try workspace()
        XCTAssertEqual(Set(names(Sidebar.build(ws, filter: "", home: "/"))),
                       ["fresh", "stale", "ancient", "old but waiting", "old unfiled"])
    }

    func testOldSessionsAreHiddenButLiveOnesStay() throws {
        let (ws, _) = try workspace()
        let tree = Sidebar.build(ws, filter: "", activeSince: daysAgo(14), home: "/")
        XCTAssertEqual(Set(names(tree)), ["fresh", "old but waiting"], "sessions needing input always show")
        let folders = tree.first?.folders.map(\.name) ?? []
        XCTAssertTrue(folders.contains("Recent"))
        XCTAssertFalse(folders.contains("Old"), "a folder whose sessions are all old is hidden")
        XCTAssertTrue(folders.contains("Empty"), "a folder that's simply empty stays")
        XCTAssertEqual(tree.first?.folders.first { $0.name == "Recent" }?.sessionCount, 1)
    }

    func testOpenTabsAndSelectionAlwaysShow() throws {
        let (ws, ids) = try workspace()
        let tree = Sidebar.build(ws, filter: "", activeSince: daysAgo(14), alwaysShow: [ids["ancient"]!], home: "/")
        XCTAssertTrue(names(tree).contains("ancient"))
    }

    func testCombinesWithTextAndStatusFilters() throws {
        let (ws, _) = try workspace()
        XCTAssertEqual(names(Sidebar.build(ws, filter: "stale", activeSince: daysAgo(14), home: "/")), [])
        XCTAssertEqual(names(Sidebar.build(ws, filter: "stale", activeSince: daysAgo(30), home: "/")), ["stale"])
        XCTAssertEqual(names(Sidebar.build(ws, filter: "", status: .completed, activeSince: daysAgo(14), home: "/")), ["fresh"])
    }

    func testCountsHiddenSessions() throws {
        let (ws, ids) = try workspace()
        XCTAssertEqual(Sidebar.hiddenByRecency(ws, activeSince: daysAgo(14), alwaysShow: []), 3)
        XCTAssertEqual(Sidebar.hiddenByRecency(ws, activeSince: daysAgo(14), alwaysShow: [ids["stale"]!]), 2)
        XCTAssertEqual(Sidebar.hiddenByRecency(ws, activeSince: nil, alwaysShow: []), 0)
    }

    func testSettingDefaultsToTwoWeeksAndZeroMeansAnyTime() throws {
        XCTAssertEqual(AppSettings().activityWindowDays, 14)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"layout":"tabs"}"#.utf8))
        XCTAssertEqual(old.activityWindowDays, 14, "existing installs get the default")
        var settings = AppSettings()
        settings.activityWindowDays = 0
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.activityWindowDays, 0)
        XCTAssertNil(roundTrip.activitySince(now: now))
        XCTAssertEqual(AppSettings().activitySince(now: now), daysAgo(14))
    }

    func testModelAppliesTheWindowAndKeepsTheSelectionVisible() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let (ws, ids) = try workspace()
            state.workspace = ws
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", now: { self.now }, home: "/")
            XCTAssertFalse(names(model.sidebar).contains("ancient"))
            XCTAssertEqual(model.hiddenByRecencyCount, 3)
            model.select(ids["ancient"]!)
            XCTAssertTrue(names(model.sidebar).contains("ancient"))

            model.setActivityWindow(days: 0)
            XCTAssertEqual(model.settings.activityWindowDays, 0)
            XCTAssertEqual(model.hiddenByRecencyCount, 0)
            model.setActivityWindow(days: -5)
            XCTAssertEqual(model.settings.activityWindowDays, 0, "negative clamps to any time")
        }
    }
}

final class ActivityWindowLabelTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(AppSettings.activityWindowLabel(days: 0), "Any time")
        XCTAssertEqual(AppSettings.activityWindowLabel(days: 1), "Last day")
        XCTAssertEqual(AppSettings.activityWindowLabel(days: 7), "Last week")
        XCTAssertEqual(AppSettings.activityWindowLabel(days: 14), "Last 2 weeks")
        XCTAssertEqual(AppSettings.activityWindowLabel(days: 45), "Last 45 days")
        XCTAssertTrue(AppSettings.activityWindowPresets.contains(AppSettings.defaultActivityWindowDays))
    }
}
