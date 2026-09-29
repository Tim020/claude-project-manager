import XCTest
@testable import ClaudioCore

/// Answers assistant calls with a canned reply (a follow-up's, written by
/// hand from the schema: no real Sonnet call has been recorded yet), and
/// everything else as `FakeRunner` does.
private final class FollowUpRunner: CommandRunning, @unchecked Sendable {
    let base = FakeRunner()
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var reply = CommandResult(exitCode: 0, output: FollowUpRunner.readyReply, errorOutput: "")

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        let args = command.claudeArguments
        guard args.contains("--json-schema") else { return await base.run(command) }
        lock.withLock { _calls.append(args) }
        return lock.withLock { reply }
    }

    /// Two notes, a new item, and "done" for i1.
    static let readyReply = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":9120,"total_cost_usd":0.041,"structured_output":{"notes":[{"text":"The shell height is stored per project in AppSettings, not per window."},{"text":"SwiftTerm resets scrollback when the view is re-created."}],"planChanges":[{"kind":"add","ref":null,"title":"Remember the Shell's scroll position","status":"idea","reason":"Found while fixing the height."},{"kind":"done","ref":"i1","title":"Remember Shell panel height","status":"done","reason":"Committed in this session."}]}}"#
}

/// History file lines, as Claude Code writes them.
private enum History {
    static func prompt(_ text: String) -> String {
        json(["type": "user", "isSidechain": false, "message": ["role": "user", "content": text]])
    }
    static func reply(_ text: String) -> String {
        json(["type": "assistant", "isSidechain": false,
              "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }
    static func tool(_ id: String, _ name: String, _ input: [String: Any], sidechain: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": sidechain,
              "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }
    static func result(_ id: String, _ text: String, error: Bool) -> String {
        json(["type": "user", "isSidechain": false,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": error]]]])
    }
    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

final class FollowUpDigestTests: XCTestCase {
    func testTheNewHookEventsParseFromRecordedPayloads() throws {
        let events = try Fixtures.lines("hook-failures.log").compactMap(HookEventParser.parse)
        XCTAssertEqual(events.map(\.name), [.postToolUseFailure, .postToolUseFailure, .stopFailure, .preToolUse])
        XCTAssertEqual(events[1].error, "Exit code 1\nls: ./no-such-folder: No such file or directory")
        XCTAssertFalse(events[1].isInterrupt)
        XCTAssertEqual(events[2].error, "authentication_failed")
        XCTAssertEqual(events[3].toolInput?["skill"]?.stringValue, "probe-skill", "the Skill tool's input key")
        XCTAssertTrue(HookSettings.events.contains(.postToolUseFailure))
        XCTAssertTrue(HookSettings.events.contains(.stopFailure))
        XCTAssertFalse(HookSettings.events.contains(.other("PermissionDenied")))
    }

    /// StopFailure comes instead of Stop, so it has to end the turn.
    func testAFailedTurnEndsTheTurnAndIsRemembered() throws {
        let failure = try XCTUnwrap(try Fixtures.lines("hook-failures.log").compactMap(HookEventParser.parse)
            .first { $0.name == .stopFailure })
        var session = Session(projectID: UUID(), name: "s", workingDirectory: "/code/app", status: .working)
        HookReducer.apply(failure, to: &session, now: Date())
        XCTAssertEqual(session.status, .completed)
        XCTAssertTrue(session.lastTurnFailed)
        var prompt = HookEvent(appSessionID: session.id, name: .userPromptSubmit)
        prompt.prompt = "try again"
        HookReducer.apply(prompt, to: &session, now: Date())
        XCTAssertFalse(session.lastTurnFailed, "a new turn clears it")
    }

    func testTheDigestSumsUpWhatHappened() {
        let lines = [
            History.prompt("Fix the shell height reset"),
            History.prompt("<command-name>/clear</command-name>"),
            History.tool("t1", "Bash", ["command": "swift test --filter ShellPanelTests"]),
            History.result("t1", "error: 2 tests failed", error: true),
            History.tool("t2", "Edit", ["file_path": "/code/app/Sources/ClaudioCore/ShellPanel.swift"]),
            History.tool("t3", "Edit", ["file_path": "/code/app/.claude/worktrees/w/Sources/Claudio/ShellPanelViews.swift"]),
            History.tool("t4", "Write", ["file_path": "/code/app/Sources/ClaudioCore/ShellPanel.swift"]),
            History.tool("t5", "Read", ["file_path": "/code/app/README.md"], sidechain: true),
            History.prompt("No, don't store it globally. Next time keep it per project."),
            History.tool("t6", "Bash", ["command": "git commit -m 'Remember the shell height'"]),
            History.tool("t7", "Bash", ["command": "gh pr create --fill"]),
            History.reply("Done: the height is stored per project."),
            "not json",
        ]
        let digest = SessionDigest.build(lines: lines, projectPath: "/code/app")
        XCTAssertEqual(digest.prompts, ["Fix the shell height reset", "No, don't store it globally. Next time keep it per project."],
                       "Claude Code's own injected text isn't a prompt")
        XCTAssertEqual(digest.corrections, ["No, don't store it globally. Next time keep it per project."])
        XCTAssertEqual(digest.failures, ["Bash: error: 2 tests failed"])
        XCTAssertEqual(digest.filesChanged, ["Sources/ClaudioCore/ShellPanel.swift", "Sources/Claudio/ShellPanelViews.swift"],
                       "relative, worktrees read as the repository, each once")
        XCTAssertEqual(digest.commits, ["git commit -m 'Remember the shell height'"])
        XCTAssertEqual(digest.pullRequestCommands, ["gh pr create --fill"])
        XCTAssertEqual(digest.finalMessage, "Done: the height is stored per project.")
        XCTAssertTrue(digest.hasSubstance)
        XCTAssertNil(digest.json(withTranscripts: false)["prompts"], "Don't send transcripts keeps only the result")
    }

    func testAQuickQuestionHasNoSubstance() {
        let quick = SessionDigest.build(lines: [History.prompt("What does ShellPanel do?"), History.reply("It runs shells.")],
                                        projectPath: "/code/app")
        XCTAssertFalse(quick.hasSubstance, "a quick question and answer never costs a call")
        let three = SessionDigest.build(lines: ["a?", "b?", "c?"].map(History.prompt), projectPath: "/code/app")
        XCTAssertTrue(three.hasSubstance, "three prompts since the last follow-up")
        XCTAssertTrue(SessionDigest.isCorrection("remember that tests run on Linux too"))
        XCTAssertFalse(SessionDigest.isCorrection("Now add a test"))
    }

    func testHistorySlicesTakeWholeLinesAfterTheMark() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("s.jsonl")
        try "one\ntwo\nthr".write(to: url, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(HistorySlice.read(url, from: 0))
        XCTAssertEqual(first.lines, ["one", "two"])
        XCTAssertEqual(first.end, 8)
        try "one\ntwo\nthree\nfour\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(HistorySlice.read(url, from: first.end)?.lines, ["three", "four"])
        XCTAssertEqual(HistorySlice.read(url, from: 5)?.lines, ["three", "four"], "a mark mid-line skips to the next line")
        XCTAssertEqual(HistorySlice.read(url, from: 19)?.lines, [])
        XCTAssertNil(HistorySlice.read(url.appendingPathExtension("gone"), from: 0))
    }

    func testARepliesPlanChangesAreChecked() throws {
        let a = PlanItem(title: "Remember Shell panel height", status: .planned, createdAt: Date())
        let done = PlanItem(title: "Old", status: .done, createdAt: Date())
        let request = FollowUpJob.request(digest: SessionDigest(), mark: FollowUpMark(conversationID: "c", offset: 0),
                                          sessionName: "s", items: [a, done], sessionItem: a, sessionNotes: [],
                                          memoryIndex: "- [Memory](m.md)")
        XCTAssertEqual(request.refs, ["i1": a.id], "done items aren't offered")
        XCTAssertEqual(request.call.model, "sonnet")
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(request.call.input.utf8))
        XCTAssertEqual(input["sessionItem"]?.stringValue, "i1")
        XCTAssertEqual(input["memoryIndex"]?.stringValue, "- [Memory](m.md)")

        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"notes":[{"text":"  One  "},{"text":""},{"text":"2"},{"text":"3"},{"text":"4"},{"text":"5"},{"text":"6"}],
             "planChanges":[
               {"kind":"add","ref":null,"title":"  New work\nsecond line","status":"idea","reason":"found it"},
               {"kind":"add","ref":null,"title":"","status":"planned","reason":"x"},
               {"kind":"done","ref":"i9","title":"x","status":"done","reason":"x"},
               {"kind":"move","ref":"i1","title":"x","status":"inSession","reason":"x"},
               {"kind":"move","ref":"i1","title":"x","status":"idea","reason":"parked"},
               {"kind":"done","ref":"i1","title":"x","status":"done","reason":"committed"}]}
            """#.utf8))
        let result = FollowUpJob.result(from: reply, refs: request.refs, items: [a, done])
        XCTAssertEqual(result.notes, ["One", "2", "3", "4", "5"], "trimmed, empty ones dropped, five at most")
        XCTAssertEqual(result.planChanges.map(\.kind), [.add, .move, .done])
        XCTAssertEqual(result.planChanges[0].title, "New work")
        XCTAssertEqual(result.planChanges[0].status, .idea)
        XCTAssertEqual(result.planChanges[0].reason, "Found it.")
        XCTAssertEqual(result.planChanges[1].status, .idea)
        XCTAssertEqual(result.planChanges[2].itemID, a.id)
        XCTAssertEqual(result.planChanges[2].label, "Mark Done")
    }
}

final class FollowUpModelTests: XCTestCase {
    static let now = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!

    private struct Fixture {
        let model: AppModel
        let runner: FollowUpRunner
        let assistant: MemoryAssistantStore
        let project: UUID
        let session: UUID
        let history: URL
    }

    /// A finished session (quiet for 10 minutes) with a history file, and a
    /// model signed in with an API key, so background work runs.
    private func makeFixture(assistant: MemoryAssistantStore = MemoryAssistantStore(),
                             lines: [String] = [History.prompt("Fix the shell height"), History.reply("Looking.")],
                             mark: Bool = false) async throws -> Fixture {
        let runner = FollowUpRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        let claudeHome = try makeTemporaryDirectory()
        let conversation = "c0ffee00-1111-2222-3333-444455556666"
        let directory = claudeHome.appendingPathComponent("projects/-code-app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("\(conversation).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: history, atomically: true, encoding: .utf8)
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        var session = Session(projectID: project, claudeSessionID: conversation, hasConversation: true, name: "Shell Height",
                              workingDirectory: "/code/app", status: .completed,
                              lastActivity: FollowUpModelTests.now.addingTimeInterval(-600))
        if mark { session.followUpMark = FollowUpMark(conversationID: conversation, offset: 0) }
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = await MainActor.run {
            AppModel(store: store, discovery: SessionDiscovery(claudeHome: claudeHome),
                     hookEventsURL: claudeHome.appendingPathComponent("h.log"), runner: runner, assistantStore: assistant,
                     locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil }, shell: "/bin/sh",
                     now: { FollowUpModelTests.now }, home: "/")
        }
        await model.checkEnvironment(force: true)
        return Fixture(model: model, runner: runner, assistant: assistant, project: project, session: session.id, history: history)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private let substantial = [
        History.prompt("Store it per project instead"),
        History.tool("t1", "Edit", ["file_path": "/code/app/Sources/ClaudioCore/ShellPanel.swift"]),
        History.reply("Stored per project."),
    ]

    func testOldSessionsGetAMarkAndNoCall() async throws {
        let f = try await makeFixture(lines: ["a", "b", "c"].map(History.prompt))
        await f.model.checkFollowUps()
        await f.model.waitForAssistantJobs()
        let mark = await MainActor.run { f.model.workspace.session(f.session)?.followUpMark }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.history.path)[.size] as? NSNumber)
        XCTAssertEqual(mark, FollowUpMark(conversationID: "c0ffee00-1111-2222-3333-444455556666", offset: size.uint64Value))
        XCTAssertTrue(f.runner.calls.isEmpty, "upgrading never starts a burst of follow-ups")
    }

    func testAFinishedSessionIsFollowedUp() async throws {
        let f = try await makeFixture()
        await f.model.checkFollowUps()          // the baseline
        try append(substantial, to: f.history)
        await MainActor.run { _ = f.model.addNote("Panel height", author: .user, projectID: f.project, sessionID: nil) }
        let item = try await MainActor.run { () -> PlanItem in
            let note = try XCTUnwrap(f.model.notes(inProject: f.project).first)
            return try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project, title: "Remember Shell panel height"))
        }
        await f.model.checkFollowUps()
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1)
        XCTAssertTrue(f.runner.calls[0].containsSequence(["--model", "sonnet"]))
        try await MainActor.run {
            let followUp = try XCTUnwrap(f.model.followUpCard(forSession: f.session))
            XCTAssertEqual(followUp.state, .ready)
            XCTAssertFalse(followUp.askedFor)
            XCTAssertEqual(followUp.notes.count, 2)
            let saved = f.model.notes(inProject: f.project).filter { $0.author == .assistant }
            XCTAssertEqual(saved.count, 2, "notes are saved straight away")
            XCTAssertEqual(saved.first?.sessionID, f.session)
            XCTAssertEqual(followUp.planChanges.map(\.kind), [.add, .done])
            XCTAssertEqual(followUp.planChanges[1].itemID, item.id)
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1)
            XCTAssertEqual(f.model.item(item.id, inProject: f.project)?.status, .planned, "the plan waits for you")
            XCTAssertEqual(f.assistant.needsYou[f.project]?.followUps.count, 1, "saved")
        }
        let calls = f.runner.calls.count
        await f.model.checkFollowUps()
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, calls, "nothing new since, so no call")
    }

    func testTheCardsActions() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        await f.model.checkFollowUps()
        await f.model.waitForAssistantJobs()
        try await MainActor.run {
            let followUp = try XCTUnwrap(f.model.followUpCard(forSession: f.session))
            let row = followUp.notes[0]
            f.model.toggleFollowUpNote(row.id, in: followUp.id, projectID: f.project)
            XCTAssertEqual(f.model.notes(inProject: f.project).filter { $0.author == .assistant }.count, 1, "unticked: removed")
            f.model.toggleFollowUpNote(row.id, in: followUp.id, projectID: f.project)
            XCTAssertEqual(f.model.notes(inProject: f.project).filter { $0.author == .assistant }.count, 2, "ticked: saved again")

            f.model.deferFollowUp(followUp.id, projectID: f.project)
            XCTAssertNil(f.model.followUpCard(forSession: f.session), "Later: off the session")
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1, "and waiting in Needs You")

            // The "done" change refers to no item here (the plan was empty), so only the new item is offered.
            XCTAssertEqual(followUp.planChanges.map(\.kind), [.add])
            f.model.addFollowUpPlanChanges(followUp.id, projectID: f.project)
            XCTAssertEqual(f.model.items(inProject: f.project).map(\.title), ["Remember the Shell's scroll position"])
            XCTAssertEqual(f.model.items(inProject: f.project).first?.status, .idea)
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 0, "closed")
            XCTAssertEqual(f.model.toast?.text, "Added 1 change to the plan")
        }
    }

    func testNothingIsAskedWithoutSubstanceOrInManualMode() async throws {
        let f = try await makeFixture(lines: [History.prompt("What does this do?"), History.reply("It runs shells.")], mark: true)
        await f.model.checkFollowUps()
        XCTAssertTrue(f.runner.calls.isEmpty, "a quick question isn't worth a call")

        try append(substantial, to: f.history)
        await MainActor.run { f.model.setAssistantMode(.manual, projectID: f.project) }
        await f.model.checkFollowUps()
        XCTAssertTrue(f.runner.calls.isEmpty, "Manual: only when you ask")

        await MainActor.run { f.model.reviewSession(f.session) }
        try await waitUntil { await MainActor.run { f.model.followUpCard(forSession: f.session) != nil } }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "Review This Session asks straight away")
        let askedFor = await MainActor.run { f.model.followUpCard(forSession: f.session)?.askedFor }
        XCTAssertEqual(askedFor, true)
    }

    func testAFailedTurnOrADailyLimitHoldsItBack() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        await MainActor.run { f.model.applyTestFailedTurn(f.session, true) }
        await f.model.checkFollowUps()
        XCTAssertTrue(f.runner.calls.isEmpty, "not after a turn that ended in an API error")

        await MainActor.run {
            f.model.applyTestFailedTurn(f.session, false)
            f.assistant.dailyJobs = DailyJobCount(day: DailyJobCount.day(of: FollowUpModelTests.now), count: AppModel.dailyJobLimit)
            f.model.dailyJobs = nil
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .paused("Daily limit of 20 reached"))
        }
        await f.model.checkFollowUps()
        XCTAssertTrue(f.runner.calls.isEmpty, "the daily limit caps background calls")
    }

    func testAFailedFollowUpCanBeTriedAgain() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        f.runner.reply = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-api-error.json"), errorOutput: "")
        await f.model.checkFollowUps()
        await f.model.waitForAssistantJobs()
        let (id, mark) = try await MainActor.run { () -> (UUID, FollowUpMark?) in
            let followUp = try XCTUnwrap(f.model.followUpCard(forSession: f.session))
            guard case .failed = followUp.state else { throw XCTSkip("expected a failure") }
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1, "a failure waits for you")
            return (followUp.id, f.model.workspace.session(f.session)?.followUpMark)
        }
        XCTAssertEqual(mark?.offset, 0, "the mark stays, so nothing is skipped")
        f.runner.reply = CommandResult(exitCode: 0, output: FollowUpRunner.readyReply, errorOutput: "")
        await MainActor.run { f.model.retryFollowUp(id, projectID: f.project) }
        await f.model.waitForAssistantJobs()
        let state = await MainActor.run { f.model.followUp(id, inProject: f.project)?.state }
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(f.runner.calls.count, 2)
    }

    func testNeedsYouSurvivesARelaunchButWorkingOnesDont() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant, lines: substantial, mark: true)
        await f.model.checkFollowUps()
        await f.model.waitForAssistantJobs()
        try await MainActor.run {
            let working = FollowUp(sessionID: UUID(), sessionName: "x", state: .working, createdAt: Date(), askedFor: false)
            f.model.updateNeedsYou(f.project) { $0.followUps.append(working) }
            XCTAssertEqual(assistant.needsYou[f.project]?.followUps.map(\.state), [.ready], "working isn't saved")

            // A note deleted meanwhile is shown as not kept after a relaunch.
            let followUp = try XCTUnwrap(f.model.followUpCard(forSession: f.session))
            let gone = try XCTUnwrap(followUp.notes[0].noteID)
            f.model.deleteNote(gone, projectID: f.project)
            f.model.needsYou = [:]
            f.model.loadNeedsYou()
            let restored = f.model.needsYouData(inProject: f.project).followUps
            XCTAssertEqual(restored.map(\.state), [.ready])
            XCTAssertEqual(restored.first?.notes.map(\.isKept), [false, true])
        }
    }

    func testSessionsSuggestPlanChanges() async throws {
        let f = try await makeFixture(mark: true)
        let text = "Add a word count to the capture box"
        await MainActor.run {
            f.assistant.inbox = ["c0ffee00-1111-2222-3333-444455556666\t/code/app\tsuggest\t\(Data(text.utf8).base64EncodedString())"]
            f.model.pollAssistantInbox()
            let suggestion = f.model.needsYouData(inProject: f.project).suggestions.first
            XCTAssertEqual(suggestion?.text, text)
            XCTAssertEqual(suggestion?.sessionID, f.session)
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1)
            XCTAssertTrue(f.model.items(inProject: f.project).isEmpty, "nothing changes until you add it")
            f.model.acceptSessionSuggestion(suggestion!.id, projectID: f.project, status: .idea)
            XCTAssertEqual(f.model.items(inProject: f.project).map(\.title), [text])
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 0)
        }
    }

    func testAQueuedJobWithTheSameKeyIsReplaced() async throws {
        let f = try await makeFixture(mark: true)
        let finished = await MainActor.run { Finished() }
        let call = AssistantCall(job: "t", model: "haiku", systemPrompt: "", schema: "{}", input: "{}")
        await MainActor.run {
            // One at a time per project: A runs, B waits and is replaced by B2.
            f.model.runAssistantJob(call, projectID: f.project, subject: "a", key: "a") { _ in finished.names.append("a") }
            f.model.runAssistantJob(call, projectID: f.project, subject: "b", key: "b") { _ in finished.names.append("b") }
            XCTAssertTrue(f.model.isAssistantJobQueued(key: "b"), "same project: it waits")
            f.model.runAssistantJob(call, projectID: f.project, subject: "b2", key: "b") { _ in finished.names.append("b2") }
        }
        await f.model.waitForAssistantJobs()
        try await waitUntil { await MainActor.run { finished.names.count == 2 } }
        let names = await MainActor.run { finished.names }
        XCTAssertEqual(names, ["a", "b2"])
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out")
    }
}

@MainActor private final class Finished {
    var names: [String] = []
}

extension AppModel {
    func applyTestFailedTurn(_ sessionID: UUID, _ failed: Bool) {
        applyTestSessionChange(sessionID) { $0.lastTurnFailed = failed }
    }
}
