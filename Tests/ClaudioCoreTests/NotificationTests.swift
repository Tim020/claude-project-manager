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

            // Each session replaces its own notification, but they all stack in
            // one group, so Notification Centre can clear them together.
            XCTAssertEqual(Set(notifier.posted.map(\.identifier)), [a.uuidString, b.uuidString])
            XCTAssertEqual(Set(notifier.posted.map(\.threadIdentifier)), [SessionNotification.sessionsThread])
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

    func testEveryPanesShownTabCountsAsVisible() throws {
        try MainActor.assumeIsolated {
            let (model, a, b) = try makeModel()
            model.select(a)
            model.select(b)
            model.splitTab(b, to: .right, of: model.panes.focusedGroupID)
            model.select(b)
            model.appIsActive = true
            model.applyStatus(a, .awaitingInput)
            model.checkNotifications()
            XCTAssertTrue(notifier.posted.isEmpty, "shown in a pane without focus")

            // Put both in one pane again: a is now behind b.
            model.moveTab(a, toPane: model.panes.focusedGroupID)
            model.select(b)
            model.applyStatus(a, .working)
            model.checkNotifications()
            model.applyStatus(a, .awaitingInput)
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.map(\.sessionID), [a], "a tab behind another is notified")
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

    /// "Notification Grouping" (2.1.285): its Stop hook marked it Completed,
    /// but the agent list says `state: "working"` (Claude Code thinks the task
    /// goes on: it was waiting on CI) with `status: "idle"`. It stays Completed,
    /// and says it finished.
    func testAnIdleAgentWhoseTaskGoesOnIsntWorking() throws {
        try MainActor.assumeIsolated {
            let (model, a, _) = try makeModel()
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "busy", state: "working", waitingFor: nil, startedAt: nil)])
            model.checkNotifications()
            XCTAssertEqual(model.workspace.session(a)?.status, .working)
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "idle", state: "working", waitingFor: nil, startedAt: nil)])
            model.checkNotifications()
            XCTAssertEqual(model.workspace.session(a)?.status, .completed)
            XCTAssertEqual(notifier.posted.map(\.kind), [.finished])
        }
    }

    /// A turn that ended with a question: the Stop hook says it's waiting on
    /// you, and an idle agent in the list doesn't turn that into Completed.
    func testAnIdleAgentKeepsAQuestionWaiting() throws {
        try MainActor.assumeIsolated {
            let (model, a, _) = try makeModel()
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "busy", state: "working", waitingFor: nil, startedAt: nil)])
            model.applyStatus(a, .awaitingInput, summary: "Shall I open the PR?")
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "idle", state: "working", waitingFor: nil, startedAt: nil)])
            XCTAssertEqual(model.workspace.session(a)?.status, .awaitingInput)
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "busy", state: "working", waitingFor: nil, startedAt: nil)])
            XCTAssertEqual(model.workspace.session(a)?.status, .working, "you answered, so it's working again")
        }
    }

    /// With no hooks (an agent started outside Claudio), Awaiting Input came
    /// from the agent list, so the list going idle ends it: the prompt was
    /// answered and the turn ended within one poll.
    func testAWaitFromTheAgentListEndsWhenItGoesIdle() throws {
        try MainActor.assumeIsolated {
            let (model, a, _) = try makeModel()
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "waiting", state: "blocked", waitingFor: "permission", startedAt: nil)])
            XCTAssertEqual(model.workspace.session(a)?.status, .awaitingInput)
            model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "idle", state: "working", waitingFor: nil, startedAt: nil)])
            XCTAssertEqual(model.workspace.session(a)?.status, .completed)
            XCTAssertNil(model.workspace.session(a)?.needsAction)
        }
    }

    /// A question the hooks saw doesn't outlive the agent's process.
    func testAQuestionEndsWhenTheAgentExits() throws {
        try MainActor.assumeIsolated {
            let (model, a, _) = try makeModel()
            for state in ["working", "failed"] {
                model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: 5, status: "busy", state: "working", waitingFor: nil, startedAt: nil)])
                model.applyStatus(a, .awaitingInput, summary: "Shall I open the PR?")
                model.apply([BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: nil, status: nil, state: state, waitingFor: nil, startedAt: nil)])
                XCTAssertEqual(model.workspace.session(a)?.status, .completed, state)
            }
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

final class UsageResetNotificationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(session: Double?, week: Double?, sessionResets: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(fiveHour: session.map { UsageWindow(usedPercentage: $0, resetsAt: sessionResets) },
                      sevenDay: week.map { UsageWindow(usedPercentage: $0, resetsAt: nil) },
                      subscriptionType: nil, updatedAt: start)
    }

    func testOnlyALimitThatWasReachedCountsAsReset() {
        var tracker = UsageResetTracker()
        XCTAssertEqual(tracker.check(nil, now: start), [], "no reading yet")
        XCTAssertEqual(tracker.check(snapshot(session: 100, week: 40), now: start), [], "the first reading is the baseline")
        XCTAssertEqual(tracker.check(snapshot(session: 100, week: 30), now: start), [], "a lower figure under the limit isn't a reset")
        XCTAssertEqual(tracker.check(snapshot(session: nil, week: 30), now: start), [], "a missing window tells us nothing")
        XCTAssertEqual(tracker.check(snapshot(session: 2, week: 30), now: start), [.session])
        XCTAssertEqual(tracker.check(snapshot(session: 2, week: 30), now: start), [], "once")
    }

    func testTheResetTimePassingCountsWithoutANewReading() {
        var tracker = UsageResetTracker()
        let resets = start.addingTimeInterval(600)
        let reading = snapshot(session: 100, week: 100, sessionResets: resets)
        XCTAssertEqual(tracker.check(reading, now: start), [])
        XCTAssertEqual(tracker.check(reading, now: resets.addingTimeInterval(-1)), [])
        XCTAssertEqual(tracker.check(reading, now: resets), [.session])
        // Claude Code's cached answer from before the reset doesn't re-arm it.
        XCTAssertEqual(tracker.check(reading, now: resets.addingTimeInterval(30)), [])
    }

    func testALimitReachedAtLaunchNotifiesWhenItResets() {
        var tracker = UsageResetTracker()
        XCTAssertEqual(tracker.check(snapshot(session: 100, week: nil), now: start), [])
        XCTAssertEqual(tracker.check(snapshot(session: 0, week: nil), now: start), [.session])
    }

    func testTheModelPostsAndLogsResets() async throws {
        try await checkModel(notify: true)
    }

    func testTurnedOffItIsOnlyLogged() async throws {
        try await checkModel(notify: false)
    }

    func testTheSettingDefaultsOn() throws {
        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"finished":false}"#.utf8))
        XCTAssertTrue(decoded.usageReset, "on for settings saved before it existed")
    }

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func checkModel(notify: Bool) async throws {
        let runner = FakeRunner()
        // The fixture's weekly window resets on 2026-09-28; keep the clock before it.
        let full = try Fixtures.string("usage-stream.jsonl").replacingOccurrences(of: #""percent":42"#, with: #""percent":100"#)
        runner.usageOutput = full
        let clock = Clock()
        clock.date = ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z")!
        let (model, notifier) = try await MainActor.run {
            let model = AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                                 locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh",
                                 now: { clock.date }, home: "/")
            let notifier = FakeNotifier()
            model.notifier = notifier
            var settings = model.settings
            settings.notifications.usageReset = notify
            model.updateSettings(settings)
            return (model, notifier)
        }
        await model.refreshUsage()
        await MainActor.run {
            model.checkUsageNotifications()
            XCTAssertTrue(notifier.posted.isEmpty, "at the limit: nothing to say yet")
            runner.usageOutput = full.replacingOccurrences(of: #""percent":100"#, with: #""percent":1"#)
            clock.date += 60
        }
        await model.refreshUsage()
        await MainActor.run {
            model.checkUsageNotifications()
            XCTAssertTrue(model.log.entries.contains { $0.title == "Weekly limit reset" }, "logged either way")
            if notify {
                XCTAssertEqual(notifier.posted, [SessionNotification(usageReset: .week)])
                XCTAssertNil(notifier.posted.first?.sessionID)
                XCTAssertEqual(notifier.posted.first?.identifier, "usage-reset-week")
                XCTAssertEqual(notifier.posted.first?.threadIdentifier, SessionNotification.usageThread)
            } else {
                XCTAssertTrue(notifier.posted.isEmpty)
            }
        }
    }
}
