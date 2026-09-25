import XCTest
@testable import ClaudioCore

final class FakeNotifier: NotificationPosting {
    var posted: [SessionNotification] = []
    func post(_ notification: SessionNotification, sound: Bool) { posted.append(notification) }
}

/// Test bodies hop to the main actor explicitly: a `@MainActor` test class
/// breaks test discovery on Linux.
final class NotificationTests: XCTestCase {
    var notifier: FakeNotifier!
    var store = MemoryStore()

    @MainActor
    private func makeModel() throws -> (AppModel, UUID, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: "/code/DigiScript")
        let a = Session(projectID: p, claudeSessionID: "a", hasConversation: true, name: "storage fix", workingDirectory: "/code/DigiScript", status: .completed)
        let b = Session(projectID: p, claudeSessionID: "b", hasConversation: true, name: "pr review", workingDirectory: "/code/DigiScript", status: .completed)
        try state.workspace.addSession(a)
        try state.workspace.addSession(b)
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        notifier = FakeNotifier()
        model.notifier = notifier
        model.checkNotifications()   // first check only records the starting point
        return (model, a.id, b.id)
    }

    func testAwaitingInputAndFinishedNotify() throws {
        try MainActor.assumeIsolated {
            let (model, a, b) = try makeModel()
            model.applyStatus(a, .working)
            model.checkNotifications()
            XCTAssertTrue(notifier.posted.isEmpty, "starting work isn't notified")

            model.applyNeedsAction(a, "Claude needs your permission to use Bash")
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.last, SessionNotification(sessionID: a, kind: .awaitingInput,
                title: "storage fix needs your input", subtitle: "DigiScript", body: "Claude needs your permission to use Bash"))

            model.applyStatus(b, .working)
            model.checkNotifications()
            model.applyStatus(b, .completed, summary: "Round 2 review posted")
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.last?.kind, .finished)
            XCTAssertEqual(notifier.posted.last?.title, "pr review finished")
            XCTAssertEqual(notifier.posted.last?.body, "Round 2 review posted")
            XCTAssertEqual(notifier.posted.count, 2)

            model.checkNotifications()
            XCTAssertEqual(notifier.posted.count, 2, "no repeats without a new change")
        }
    }

    func testNothingAtStartupOrForNewSessions() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            try state.workspace.addSession(Session(projectID: p, name: "already waiting", workingDirectory: "/code", status: .awaitingInput))
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            let notifier = FakeNotifier()
            model.notifier = notifier
            model.checkNotifications()
            XCTAssertTrue(notifier.posted.isEmpty)
        }
    }

    func testVisibleSessionInTheFrontIsNotNotified() throws {
        try MainActor.assumeIsolated {
            let (model, a, b) = try makeModel()
            model.select(a)
            model.appIsActive = true
            model.applyStatus(a, .awaitingInput)
            model.checkNotifications()
            XCTAssertTrue(notifier.posted.isEmpty, "you're looking at it")

            model.applyStatus(b, .awaitingInput)
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.map(\.sessionID), [b], "other sessions still notify")

            model.appIsActive = false
            model.applyStatus(a, .working)
            model.checkNotifications()
            model.applyStatus(a, .awaitingInput)
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.last?.sessionID, a, "selected but Claudio is in the background")
        }
    }

    func testSettingsControlEachKind() throws {
        try MainActor.assumeIsolated {
            let (model, a, _) = try makeModel()
            var settings = model.settings
            settings.notifications.finished = false
            model.updateSettings(settings)
            model.applyStatus(a, .working)
            model.checkNotifications()
            model.applyStatus(a, .completed)
            model.checkNotifications()
            XCTAssertTrue(notifier.posted.isEmpty)
        }
    }

    func testStoppedUnexpectedlyIsOptional() throws {
        try MainActor.assumeIsolated {
            let (model, a, _) = try makeModel()
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "busy", state: "working", waitingFor: nil, startedAt: nil)])
            model.checkNotifications()
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: nil, status: nil, state: "working", waitingFor: nil, startedAt: nil)])
            model.checkNotifications()
            XCTAssertTrue(notifier.posted.isEmpty, "off by default")

            var settings = model.settings
            settings.notifications.stoppedUnexpectedly = true
            model.updateSettings(settings)
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 6, status: "busy", state: "working", waitingFor: nil, startedAt: nil)])
            model.checkNotifications()
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: nil, status: nil, state: "working", waitingFor: nil, startedAt: nil)])
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.map(\.kind), [.stopped])
            XCTAssertEqual(notifier.posted.first?.title, "storage fix stopped unexpectedly")
            _ = a
        }
    }

    func testNotificationSettingsDefaultsAndDecoding() throws {
        let defaults = NotificationSettings()
        XCTAssertTrue(defaults.awaitingInput)
        XCTAssertTrue(defaults.finished)
        XCTAssertFalse(defaults.stoppedUnexpectedly)
        XCTAssertTrue(defaults.sound)
        let decoded = try JSONFileStore.decoder.decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.notifications, defaults)
    }

    func testOpeningFromANotificationSelectsTheSession() throws {
        try MainActor.assumeIsolated {
            let (model, a, _) = try makeModel()
            model.openFromNotification(a)
            XCTAssertEqual(model.selectedSessionID, a)
            XCTAssertTrue(model.workspace.isOpen(a))
        }
    }
}
