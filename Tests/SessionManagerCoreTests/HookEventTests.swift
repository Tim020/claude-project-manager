import XCTest
@testable import SessionManagerCore

final class HookEventParserTests: XCTestCase {
    let appID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
    let sid = "11111111-2222-3333-4444-555555555555"

    func testParsesRecordedHookEvents() throws {
        let events = try Fixtures.lines("hook-events.log").compactMap(HookEventParser.parse)
        XCTAssertEqual(events.map(\.name), [
            .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .preToolUse,
            .notification, .postToolUse, .stop, .sessionEnd,
        ])
        XCTAssertTrue(events.allSatisfy { $0.appSessionID == appID && $0.claudeSessionID == sid })

        XCTAssertEqual(events[0].source, "startup")
        XCTAssertEqual(events[1].prompt, "Fix the storage bug and open a PR")
        XCTAssertEqual(events[2].toolName, "Bash")
        XCTAssertEqual(events[3].toolOutput, "hi")
        XCTAssertEqual(events[5].message, "Claude needs your permission to use Bash")
        XCTAssertEqual(events[5].notificationType, "permission_prompt")
        XCTAssertEqual(events[6].toolOutput, "https://github.com/Tim020/DigiScript/pull/1427\n")
        XCTAssertEqual(events[7].lastAssistantMessage?.hasPrefix("Opened https://github.com"), true)
        XCTAssertEqual(events[8].reason, "other")
    }

    func testRejectsMalformedLines() {
        XCTAssertNil(HookEventParser.parse(""))
        XCTAssertNil(HookEventParser.parse("no tab here"))
        XCTAssertNil(HookEventParser.parse("not-a-uuid\t{\"hook_event_name\":\"Stop\"}"))
        XCTAssertNil(HookEventParser.parse("\(appID.uuidString)\t{broken"))
        XCTAssertNil(HookEventParser.parse("\(appID.uuidString)\t{\"session_id\":\"x\"}"), "needs an event name")
    }

    func testUnknownEventNamesAreKept() {
        let event = HookEventParser.parse("\(appID.uuidString)\t{\"hook_event_name\":\"PreCompact\"}")
        XCTAssertEqual(event?.name, .other("PreCompact"))
    }

    func testToolOutputFallsBackToStringResponse() {
        let event = HookEventParser.parse("\(appID.uuidString)\t" + #"{"hook_event_name":"PostToolUse","tool_response":"plain text"}"#)
        XCTAssertEqual(event?.toolOutput, "plain text")
    }
}

final class HookEventTailerTests: XCTestCase {
    private func line(_ name: String, id: UUID = UUID()) -> String {
        "\(id.uuidString)\t{\"hook_event_name\":\"\(name)\"}\n"
    }

    func testReadsOnlyNewCompleteLines() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("events.log")
        var tailer = HookEventTailer(url: url)
        XCTAssertEqual(tailer.readNew().count, 0, "missing file is fine")

        try (line("Stop") + String(line("Notification").dropLast())).write(to: url, atomically: false, encoding: .utf8)
        XCTAssertEqual(tailer.readNew().map(\.name), [.stop])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + line("SessionEnd")).utf8))
        try handle.close()
        XCTAssertEqual(tailer.readNew().map(\.name), [.notification, .sessionEnd])
        XCTAssertEqual(tailer.readNew().count, 0)
    }

    func testStartingAtEndSkipsExistingEvents() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("events.log")
        try line("Stop").write(to: url, atomically: false, encoding: .utf8)
        var tailer = HookEventTailer(url: url, startAtEnd: true)
        XCTAssertEqual(tailer.readNew().count, 0)
    }

    func testTruncatedFileIsReadFromTheStart() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("events.log")
        try (line("Stop") + line("Stop")).write(to: url, atomically: false, encoding: .utf8)
        var tailer = HookEventTailer(url: url)
        XCTAssertEqual(tailer.readNew().count, 2)
        try line("SessionEnd").write(to: url, atomically: false, encoding: .utf8)
        XCTAssertEqual(tailer.readNew().map(\.name), [.sessionEnd])
    }
}

final class HookReducerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 9_000)

    private func session(_ status: SessionStatus = .completed) -> Session {
        Session(projectID: UUID(), claudeSessionID: "old", name: "s", workingDirectory: "/", status: status,
                createdAt: Date(timeIntervalSince1970: 0))
    }

    private func event(_ name: HookEventName, _ configure: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
        var event = HookEvent(appSessionID: UUID(), name: name)
        event.claudeSessionID = "new-id"
        configure(&event)
        return event
    }

    func testRecordedSequenceEndsCompletedWithSummaryAndPR() throws {
        var s = session()
        for event in try Fixtures.lines("hook-events.log").compactMap(HookEventParser.parse) {
            HookReducer.apply(event, to: &s, now: now)
        }
        XCTAssertEqual(s.status, .completed)
        XCTAssertEqual(s.summary, "Opened https://github.com/Tim020/DigiScript/pull/1427 with the storage fix.")
        XCTAssertEqual(s.pullRequestURLs, ["https://github.com/Tim020/DigiScript/pull/1427"])
        XCTAssertEqual(s.claudeSessionID, "11111111-2222-3333-4444-555555555555")
        XCTAssertTrue(s.hasConversation)
        XCTAssertNil(s.needsAction)
        XCTAssertEqual(s.lastActivity, now)
    }

    func testSessionStartTracksIDButNotConversation() {
        var s = session()
        HookReducer.apply(event(.sessionStart), to: &s, now: now)
        XCTAssertEqual(s.claudeSessionID, "new-id")
        XCTAssertFalse(s.hasConversation, "no transcript exists until a prompt is sent")
    }

    func testPromptAndToolsMeanWorking() {
        for name in [HookEventName.userPromptSubmit, .preToolUse, .postToolUse] {
            var s = session(.awaitingInput)
            s.needsAction = "approve"
            HookReducer.apply(event(name), to: &s, now: now)
            XCTAssertEqual(s.status, .working, "\(name)")
            XCTAssertNil(s.needsAction)
        }
    }

    func testPromptMarksConversation() {
        var s = session()
        HookReducer.apply(event(.userPromptSubmit), to: &s, now: now)
        XCTAssertTrue(s.hasConversation)
    }

    func testPermissionNotificationAwaitsInput() {
        var s = session(.working)
        HookReducer.apply(event(.notification) {
            $0.message = "Claude needs your permission to use Bash"
            $0.notificationType = "permission_prompt"
        }, to: &s, now: now)
        XCTAssertEqual(s.status, .awaitingInput)
        XCTAssertEqual(s.needsAction, "Claude needs your permission to use Bash")
    }

    func testIdleNotificationDoesNotChangeCompletedSession() {
        var s = session(.completed)
        HookReducer.apply(event(.notification) {
            $0.message = "Claude is waiting for your input"
            $0.notificationType = "idle_prompt"
        }, to: &s, now: now)
        XCTAssertEqual(s.status, .completed)

        var untyped = session(.completed)
        HookReducer.apply(event(.notification) { $0.message = "Claude is waiting for your input" }, to: &untyped, now: now)
        XCTAssertEqual(untyped.status, .completed)
    }

    func testStopWithQuestionAwaitsInput() {
        var s = session(.working)
        HookReducer.apply(event(.stop) { $0.lastAssistantMessage = "Which redirect strategy should I use?" }, to: &s, now: now)
        XCTAssertEqual(s.status, .awaitingInput)
        XCTAssertEqual(s.needsAction, "Which redirect strategy should I use?")
    }

    func testStopTruncatesLongSummary() {
        var s = session(.working)
        HookReducer.apply(event(.stop) { $0.lastAssistantMessage = String(repeating: "x", count: 400) }, to: &s, now: now)
        XCTAssertEqual(s.summary.count, HookReducer.maxSummaryLength)
    }

    func testSessionEndWhileWorkingCompletes() {
        var s = session(.working)
        HookReducer.apply(event(.sessionEnd), to: &s, now: now)
        XCTAssertEqual(s.status, .completed)

        var waiting = session(.awaitingInput)
        HookReducer.apply(event(.sessionEnd), to: &waiting, now: now)
        XCTAssertEqual(waiting.status, .awaitingInput)
    }
}
