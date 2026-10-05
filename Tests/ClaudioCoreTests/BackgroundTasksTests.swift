import XCTest
@testable import ClaudioCore

/// What a session's background tasks look like, how long they've run, and
/// marking them finished.
final class BackgroundTasksTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func stop(_ tasks: [BackgroundTaskReport]) -> HookEvent {
        var event = HookEvent(appSessionID: UUID(), name: .stop)
        event.backgroundTasks = tasks
        return event
    }

    func testEachTaskKeepsWhenItWasFirstSeen() {
        var s = Session(projectID: UUID(), name: "tests", workingDirectory: "/code", status: .working)
        HookReducer.apply(stop([BackgroundTaskReport(id: "b1", kind: "shell", description: "Run tests")]), to: &s, now: start)
        let later = start.addingTimeInterval(600)
        HookReducer.apply(stop([BackgroundTaskReport(id: "b1", kind: "shell", description: "Run tests"),
                                BackgroundTaskReport(id: "a2", kind: "subagent", description: "Review PR")]), to: &s, now: later)
        XCTAssertEqual(s.backgroundTasks, [BackgroundTask(id: "b1", kind: "shell", description: "Run tests", since: start),
                                           BackgroundTask(id: "a2", kind: "subagent", description: "Review PR", since: later)])
    }

    /// Marked finished: they no longer count while Claude Code still reports
    /// them, and the mark goes once it doesn't.
    func testTasksMarkedFinishedDontCount() {
        var s = Session(projectID: UUID(), name: "dev server", workingDirectory: "/code", status: .completed)
        s.finishedBackgroundTasks = ["b1"]
        HookReducer.apply(stop([BackgroundTaskReport(id: "b1")]), to: &s, now: start)
        XCTAssertEqual(s.status, .completed)
        XCTAssertEqual(s.backgroundTasks, [])
        HookReducer.apply(stop([BackgroundTaskReport(id: "b1"), BackgroundTaskReport(id: "b2")]), to: &s, now: start)
        XCTAssertEqual(s.status, .working, "a new task counts")
        XCTAssertEqual(s.backgroundTasks.map(\.id), ["b2"])
        HookReducer.apply(stop([BackgroundTaskReport(id: "b2")]), to: &s, now: start)
        XCTAssertEqual(s.finishedBackgroundTasks, [], "b1 ended")
    }

    func testDescribesTasks() {
        let tasks = [BackgroundTask(id: "b1", kind: "shell", description: "npm run dev", since: start),
                     BackgroundTask(id: "b2", kind: "monitor", description: "", since: start.addingTimeInterval(3600)),
                     BackgroundTask(id: "a3", kind: "subagent", description: "Review PR", since: start.addingTimeInterval(7200))]
        let now = start.addingTimeInterval(2 * 3600 + 5 * 60)
        XCTAssertEqual(BackgroundTasks.count(tasks), "3 background tasks")
        XCTAssertEqual(BackgroundTasks.count([tasks[0]]), "1 background task")
        XCTAssertEqual(BackgroundTasks.runningSince(tasks), start)
        XCTAssertEqual(BackgroundTasks.help(tasks, now: now), """
            3 background tasks running, so it stays Working until they finish:
            • npm run dev (command, 2 h 5 min)
            • b2 (Monitor, 1 h 5 min)
            • Review PR (subagent, 5 min)
            """)
        XCTAssertEqual(BackgroundTasks.duration(from: start, to: start.addingTimeInterval(3600)), "1 h")
    }

    func testLongRunningAfterHalfAnHour() {
        var s = Session(projectID: UUID(), name: "dev server", workingDirectory: "/code", status: .working)
        XCTAssertFalse(BackgroundTasks.isLongRunning(s, now: start))
        s.backgroundTasks = [BackgroundTask(id: "b1", since: start)]
        XCTAssertFalse(BackgroundTasks.isLongRunning(s, now: start.addingTimeInterval(29 * 60)))
        XCTAssertTrue(BackgroundTasks.isLongRunning(s, now: start.addingTimeInterval(30 * 60)))
    }

    // MARK: - The model

    var store = MemoryStore()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var hooks: URL!

    @MainActor
    private func makeModel() throws -> (AppModel, UUID, UUID, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: "/code/DigiScript")
        let a = Session(projectID: p, claudeSessionID: "a", hasConversation: true, name: "dev server", workingDirectory: "/code/DigiScript", status: .completed)
        let b = Session(projectID: p, claudeSessionID: "b", hasConversation: true, name: "tests", workingDirectory: "/code/DigiScript", status: .completed)
        try state.workspace.addSession(a)
        try state.workspace.addSession(b)
        store.state = state
        hooks = try makeTemporaryDirectory().appendingPathComponent("h.log")
        try Data().write(to: hooks)
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: hooks, runner: FakeRunner(), locateClaude: { _ in nil }, shell: "/bin/sh",
                             now: { [unowned self] in self.clock }, home: "/")
        return (model, p, a.id, b.id)
    }

    @MainActor
    private func hook(_ model: AppModel, _ json: String) throws {
        let handle = try FileHandle(forWritingTo: hooks)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(UUID().uuidString)\t\(json)\n".utf8))
        try handle.close()
        model.pollHookEvents()
    }

    /// Sessions whose tasks have run half an hour are in Needs You, assistant
    /// on or off, longest first, until you mark them finished.
    func testLongRunningSessionsNeedYou() throws {
        try MainActor.assumeIsolated {
            let (model, p, a, b) = try makeModel()
            try hook(model, #"{"session_id":"a","hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"npm run dev"}]}"#)
            clock = clock.addingTimeInterval(10 * 60)
            try hook(model, #"{"session_id":"b","hook_event_name":"Stop","background_tasks":[{"id":"b2","type":"shell","status":"running"}]}"#)
            XCTAssertEqual(model.workspace.session(a)?.status, .working)
            XCTAssertEqual(model.longRunningSessions(inProject: p), [])
            XCTAssertEqual(model.needsYouCount(inProject: p), 0)

            clock = clock.addingTimeInterval(25 * 60)
            XCTAssertEqual(model.longRunningSessions(inProject: p).map(\.id), [a])
            XCTAssertEqual(model.needsYouCount(inProject: p), 1, "counted with the assistant off")
            clock = clock.addingTimeInterval(10 * 60)
            XCTAssertEqual(model.longRunningSessions(inProject: p).map(\.id), [a, b], "longest first")

            model.markBackgroundTasksFinished(a)
            XCTAssertEqual(model.workspace.session(a)?.status, .completed)
            XCTAssertEqual(model.workspace.session(a)?.finishedBackgroundTasks, ["b1"])
            XCTAssertEqual(model.longRunningSessions(inProject: p).map(\.id), [b])
            XCTAssertEqual(store.state.workspace.session(a)?.finishedBackgroundTasks, ["b1"], "saved")

            // Its next turn still reports the dev server: it stays finished.
            try hook(model, #"{"session_id":"a","hook_event_name":"UserPromptSubmit","prompt":"Anything else?"}"#)
            try hook(model, #"{"session_id":"a","hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running"}]}"#)
            XCTAssertEqual(model.workspace.session(a)?.status, .completed)

            model.archive(b)
            XCTAssertEqual(model.longRunningSessions(inProject: p), [], "archived sessions aren't shown")
        }
    }

    func testMarkingFinishedNotifiesOnce() throws {
        try MainActor.assumeIsolated {
            let (model, _, a, _) = try makeModel()
            let notifier = FakeNotifier()
            model.notifier = notifier
            model.checkNotifications()
            try hook(model, #"{"session_id":"a","hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running"}]}"#)
            model.checkNotifications()
            XCTAssertTrue(notifier.posted.isEmpty)
            model.markBackgroundTasksFinished(a)
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.map(\.kind), [.finished])
            model.markBackgroundTasksFinished(a)
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.count, 1, "nothing left to mark")
        }
    }

    /// Marked finished before a relaunch: the job state still lists it, but
    /// it doesn't count.
    func testMarksSurviveARelaunch() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code/DigiScript")
            var session = Session(projectID: p, claudeSessionID: "a", hasConversation: true, name: "dev server", workingDirectory: "/code/DigiScript")
            session.agentID = "a1"
            session.finishedBackgroundTasks = ["b1"]
            try state.workspace.addSession(session)
            store.state = state
            let home = try makeTemporaryDirectory()
            let url = BackgroundJobState.url(claudeHome: home, agentID: "a1")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"fan":[{"id":"b1","kind":"shell","startedAt":1}]}"#.utf8).write(to: url)
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: home),
                                 hookEventsURL: home.appendingPathComponent("h.log"), runner: FakeRunner(),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            XCTAssertEqual(model.workspace.session(session.id)?.backgroundTasks, [])
            XCTAssertEqual(model.workspace.session(session.id)?.finishedBackgroundTasks, ["b1"])
        }
    }
}
