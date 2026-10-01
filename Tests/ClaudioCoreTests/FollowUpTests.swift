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
        let first = try HistorySlice.read(url, from: 0).get()
        XCTAssertEqual(first.lines, ["one", "two"])
        XCTAssertEqual(first.end, 8)
        try "one\ntwo\nthree\nfour\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try HistorySlice.read(url, from: first.end).get().lines, ["three", "four"])
        XCTAssertEqual(try HistorySlice.read(url, from: 5).get().lines, ["three", "four"], "a mark mid-line skips to the next line")
        XCTAssertEqual(try HistorySlice.read(url, from: 19).get().lines, [])
        XCTAssertThrowsError(try HistorySlice.read(url.appendingPathExtension("gone"), from: 0).get(),
                             "a file that can't be read is an error, not \"nothing new\"")

        // More than the cap is new: only the newest whole lines are read.
        let capped = try HistorySlice.read(url, from: 0, maxBytes: 9).get()
        XCTAssertEqual(capped.lines, ["four"], "from the first line that starts inside the last 9 bytes")
        XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.end, 19)
        XCTAssertFalse(try HistorySlice.read(url, from: 0).get().truncated)
    }

    func testNeedsYouKeepsWhatItCantRead() throws {
        let json = #"""
            {"followUps":[
               {"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","state":{"ready":{}},"askedFor":true},
               {"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","state":{"someNewState":{}}}],
             "suggestions":[{"text":"Add a word count"},{"nottext":1}]}
            """#
        let data = try JSONFileStore.decoder.decode(NeedsYouData.self, from: Data(json.utf8))
        XCTAssertEqual(data.followUps.map(\.state), [.ready], "missing defaulted fields are fine")
        XCTAssertEqual(data.suggestions.map(\.text), ["Add a word count"])
        XCTAssertEqual(data.unreadableCount, 2, "one bad entry doesn't cost the rest")
        let again = try JSONFileStore.decoder.decode(NeedsYouData.self, from: JSONFileStore.encoder.encode(data.saved))
        XCTAssertEqual(again.unreadableCount, 2, "and they're written back as they were")
        XCTAssertFalse(data.isEmpty)
    }

    func testAPlanChangeThatMakesNoSenseIsntRead() throws {
        let item = UUID().uuidString
        for json in [#"{"kind":"add","itemID":"\#(item)","title":"t","status":"planned"}"#,
                     #"{"kind":"done","itemID":"\#(item)","title":"t","status":"idea"}"#,
                     #"{"kind":"move","itemID":"\#(item)","title":"t","status":"done"}"#,
                     #"{"kind":"move","title":"t","status":"idea"}"#] {
            XCTAssertThrowsError(try JSONFileStore.decoder.decode(ProposedPlanChange.self, from: Data(json.utf8)), json)
        }
        XCTAssertNoThrow(try JSONFileStore.decoder.decode(ProposedPlanChange.self,
                                                          from: Data(#"{"kind":"add","title":"t","status":"idea"}"#.utf8)))
        XCTAssertEqual(ProposedPlanChange.add(title: "t", status: .done, reason: "").status, .planned)
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

    static let conversation = "c0ffee00-1111-2222-3333-444455556666"

    /// A Completed session with a history file, a model signed in with an
    /// API key, and (unless `task` is nil) its background agent, whose task
    /// state Claude Code reports as `task`.
    private func makeFixture(assistant: MemoryAssistantStore = MemoryAssistantStore(),
                             lines: [String] = [History.prompt("Fix the shell height"), History.reply("Looking.")],
                             mark: Bool = false, task: String? = "done") async throws -> Fixture {
        let runner = FollowUpRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        let claudeHome = try makeTemporaryDirectory()
        let conversation = FollowUpModelTests.conversation
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
        let f = Fixture(model: model, runner: runner, assistant: assistant, project: project, session: session.id, history: history)
        if let task { await setTask(task, f) }
        return f
    }

    /// What `claude agents --json` says about the session's agent.
    private func setTask(_ state: String, _ f: Fixture) async {
        await MainActor.run {
            f.model.apply([BackgroundAgent(id: "c0ffee00", sessionID: FollowUpModelTests.conversation, cwd: "/code/app",
                                           name: nil, pid: 5, status: "idle", state: state, waitingFor: nil, startedAt: nil)])
        }
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

    /// Checks for ready sessions, expects an offer, and accepts it.
    private func offerAndAccept(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        await f.model.checkFollowUps()
        let offer = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(offer?.state, .offered, file: file, line: line)
        XCTAssertTrue(f.runner.calls.isEmpty, "an offer costs nothing", file: file, line: line)
        guard let offer else { return }
        await MainActor.run { f.model.acceptFollowUpOffer(offer.id, projectID: f.project) }
        await f.model.waitForAssistantJobs()
    }

    func testOldSessionsGetAMarkAndNothingElse() async throws {
        let f = try await makeFixture(lines: ["a", "b", "c"].map(History.prompt))
        await f.model.checkFollowUps()
        let (mark, card) = await MainActor.run {
            (f.model.workspace.session(f.session)?.followUpMark, f.model.followUpCard(forSession: f.session))
        }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.history.path)[.size] as? NSNumber)
        XCTAssertEqual(mark, FollowUpMark(conversationID: FollowUpModelTests.conversation, offset: size.uint64Value))
        XCTAssertNil(card, "upgrading offers nothing for what old sessions already did")
        XCTAssertTrue(f.runner.calls.isEmpty)
    }

    func testAReadySessionIsOfferedAFollowUpAndItRunsWhenAccepted() async throws {
        let f = try await makeFixture()
        await f.model.checkFollowUps()          // the baseline
        try append(substantial, to: f.history)
        await MainActor.run { _ = f.model.addNote("Panel height", author: .user, projectID: f.project, sessionID: nil) }
        let item = try await MainActor.run { () -> PlanItem in
            let note = try XCTUnwrap(f.model.notes(inProject: f.project).first)
            return try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project, title: "Remember Shell panel height"))
        }
        await f.model.checkFollowUps()
        await MainActor.run {
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1, "an offer waits for you")
            XCTAssertNil(f.assistant.needsYou[f.project], "offers aren't saved")
        }
        try await offerAndAccept(f)
        XCTAssertEqual(f.runner.calls.count, 1)
        XCTAssertTrue(f.runner.calls[0].containsSequence(["--model", "sonnet"]))
        try await MainActor.run {
            let followUp = try XCTUnwrap(f.model.followUpCard(forSession: f.session))
            XCTAssertEqual(followUp.state, .ready)
            XCTAssertTrue(followUp.askedFor, "accepting an offer is something you started")
            XCTAssertEqual(followUp.notes.count, 2)
            let saved = f.model.notes(inProject: f.project).filter { $0.author == .assistant }
            XCTAssertEqual(saved.count, 2, "notes are saved straight away")
            XCTAssertEqual(saved.first?.sessionID, f.session)
            XCTAssertEqual(followUp.planChanges.map(\.kind), [.add, .done])
            XCTAssertEqual(followUp.planChanges[1].itemID, item.id)
            XCTAssertEqual(f.model.item(item.id, inProject: f.project)?.status, .planned, "the plan waits for you")
            XCTAssertEqual(f.assistant.needsYou[f.project]?.followUps.count, 1, "saved")
        }
        await f.model.checkFollowUps()
        let (card, mark) = await MainActor.run {
            (f.model.followUpCard(forSession: f.session), f.model.workspace.session(f.session)?.followUpMark)
        }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.history.path)[.size] as? NSNumber)
        XCTAssertEqual(card?.state, .ready, "no new offer: nothing new since")
        XCTAssertEqual(mark?.offset, size.uint64Value, "the mark moved to the history's end")
        XCTAssertEqual(f.runner.calls.count, 1)
    }

    /// Claude Code's own view decides: "working" means it expects to carry on.
    func testOnlyAFinishedTaskIsOffered() async throws {
        let f = try await makeFixture(lines: substantial, mark: true, task: "working")
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "Claude Code says the task goes on")
        await setTask("review_ready", f)
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered, "ready for review")
    }

    /// Stopping a session (or closing its tab) is a sign too, for direct
    /// tabs with no task state as well.
    func testStoppingASessionMakesItReady() async throws {
        let f = try await makeFixture(lines: substantial, mark: true, task: nil)
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "no agent, no task state: not yet")
        await MainActor.run { f.model.stop(f.session) }
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered)
    }

    /// Stop Session on a background agent mid-task: `claude stop` leaves it
    /// listed with no process and `state: "stopped"` (recorded with 2.1.285 in
    /// `agents-after-stop.json`), so it isn't Working, and it's offered.
    func testStoppingAnAgentMidTaskMakesItReady() async throws {
        let f = try await makeFixture(lines: substantial, mark: true, task: "working")
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card)
        await MainActor.run {
            f.model.stop(f.session)
            f.model.apply([BackgroundAgent(id: "c0ffee00", sessionID: FollowUpModelTests.conversation, cwd: "/code/app",
                                           name: nil, pid: nil, status: nil, state: "stopped", waitingFor: nil, startedAt: nil)])
            XCTAssertEqual(f.model.workspace.session(f.session)?.status, .completed, "no process, so not working")
        }
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered)
    }

    func testANewPromptWithdrawsTheOffer() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        await f.model.checkFollowUps()
        let hookLog = f.history.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("h.log")
        let line = f.session.uuidString + "\t" + History.json(["hook_event_name": "UserPromptSubmit", "session_id": FollowUpModelTests.conversation,
                                                               "prompt": "One more thing"]) + "\n"
        try line.write(to: hookLog, atomically: true, encoding: .utf8)
        await MainActor.run {
            XCTAssertEqual(f.model.followUpCard(forSession: f.session)?.state, .offered)
            f.model.pollHookEvents()
            XCTAssertNil(f.model.followUpCard(forSession: f.session), "it's carrying on, so the offer goes")
            XCTAssertEqual(f.model.workspace.session(f.session)?.status, .working)
        }
    }

    func testNotNowWaitsForMoreActivity() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        await f.model.checkFollowUps()
        await MainActor.run {
            let offer = f.model.followUpCard(forSession: f.session)!
            f.model.declineFollowUpOffer(offer.id, projectID: f.project)
        }
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "not offered again for the same history")
        // A relaunch: offers and what was checked are gone, but Not Now is kept.
        await MainActor.run {
            f.model.needsYou = [:]
            f.model.followUpChecked = [:]
            f.model.loadNeedsYou()
        }
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "Not Now survives a relaunch")
        try append([History.prompt("And the width too"), History.reply("Done.")], to: f.history)
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered, "offered again once it's done more")
        XCTAssertTrue(f.runner.calls.isEmpty)
    }

    func testTheCardsActions() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        try await offerAndAccept(f)
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

    func testNothingIsOfferedWithoutSubstanceOrInManualMode() async throws {
        let f = try await makeFixture(lines: [History.prompt("What does this do?"), History.reply("It runs shells.")], mark: true)
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "a quick question isn't worth a follow-up")

        try append(substantial, to: f.history)
        await MainActor.run { f.model.setAssistantMode(.manual, projectID: f.project) }
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "Manual: only when you ask")

        await MainActor.run { f.model.reviewSession(f.session) }
        try await waitUntil { await MainActor.run { f.model.followUpCard(forSession: f.session) != nil } }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "Review This Session asks straight away")
        let askedFor = await MainActor.run { f.model.followUpCard(forSession: f.session)?.askedFor }
        XCTAssertEqual(askedFor, true)
    }

    /// A turn cut short by a usage limit or an API error isn't a finish.
    /// Offers cost nothing, so usage and the daily limit don't hold them back.
    func testAFailedTurnHoldsTheOfferBackButLimitsDont() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        await MainActor.run { f.model.applyTestFailedTurn(f.session, true) }
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "not after a turn that ended in an API error")

        await MainActor.run {
            f.model.applyTestFailedTurn(f.session, false)
            f.assistant.dailyJobs = DailyJobCount(day: DailyJobCount.day(of: FollowUpModelTests.now), count: AssistantAppSettings.defaultDailyJobLimit)
            f.model.dailyJobs = nil
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .paused("Daily limit of 20 reached"))
        }
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered)
        await MainActor.run { f.model.acceptFollowUpOffer(card!.id, projectID: f.project) }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "you started it, so the daily limit doesn't apply")
    }

    func testAFailedFollowUpCanBeTriedAgain() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        f.runner.reply = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-api-error.json"), errorOutput: "")
        try await offerAndAccept(f)
        let (id, mark) = try await MainActor.run { () -> (UUID, FollowUpMark?) in
            let followUp = try XCTUnwrap(f.model.followUpCard(forSession: f.session))
            guard case .failed(let message) = followUp.state else {
                XCTFail("expected a failure, got \(followUp.state)")
                throw CancellationError()
            }
            XCTAssertFalse(message.isEmpty)
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
        try await offerAndAccept(f)
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
            f.assistant.inbox = ["\(FollowUpModelTests.conversation)\t/code/app\tsuggest\t\(Data(text.utf8).base64EncodedString())"]
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

    /// A session made after this build is offered a follow-up the first time
    /// it's ready, not given a baseline.
    func testANewSessionsFirstFinishIsOffered() async throws {
        let f = try await makeFixture(mark: true)
        let id = try await MainActor.run { () -> UUID in
            let request = NewSessionRequest(projectID: f.project, folderID: nil, name: "New", role: .code, prompt: "",
                                            model: nil, permissionMode: .standard)
            let id = try XCTUnwrap(f.model.createSession(request))
            XCTAssertEqual(f.model.workspace.session(id)?.followUpMark, FollowUpMark(conversationID: "", offset: 0))
            f.model.terminalExited(id, exitCode: 0)
            f.model.applyTestSessionChange(id) {
                $0.hasConversation = true
                $0.status = .completed
            }
            return id
        }
        let conversation = try await MainActor.run { try XCTUnwrap(f.model.workspace.session(id)?.claudeSessionID) }
        let history = f.history.deletingLastPathComponent().appendingPathComponent("\(conversation).jsonl")
        try (substantial.joined(separator: "\n") + "\n").write(to: history, atomically: true, encoding: .utf8)
        await f.model.checkFollowUps()
        let state = await MainActor.run { f.model.followUpCard(forSession: id)?.state }
        XCTAssertEqual(state, .offered, "no baseline: everything it did is new")
    }

    func testAMissingHistoryFileIsntLookedForEveryTick() async throws {
        let f = try await makeFixture(mark: true)
        try FileManager.default.removeItem(at: f.history)
        await f.model.checkFollowUps()
        let missing = await MainActor.run { f.model.followUpHistoryMissing[f.session] }
        XCTAssertEqual(missing, FollowUpModelTests.conversation, "remembered until the next launch")
        XCTAssertTrue(f.runner.calls.isEmpty)
    }

    // MARK: Review round 1 (PR #28)

    /// Not Now holds until a new prompt: a rename's title line, or Claude
    /// Code's bookkeeping, grows the history without one.
    func testNotNowIgnoresHistoryLinesThatArentPrompts() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        await f.model.checkFollowUps()
        await MainActor.run {
            let offer = f.model.followUpCard(forSession: f.session)!
            f.model.declineFollowUpOffer(offer.id, projectID: f.project)
        }
        try append([History.json(["type": "custom-title", "customTitle": "Renamed", "sessionId": FollowUpModelTests.conversation])],
                   to: f.history)
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card, "only a title line since Not Now")
        try append([History.prompt("One more thing"), History.reply("Done.")], to: f.history)
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered, "a new prompt since")
    }

    /// A failed follow-up isn't left beside a new offer for the same work.
    func testANewOfferReplacesAFailedCard() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        f.runner.reply = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-api-error.json"), errorOutput: "")
        try await offerAndAccept(f)
        await MainActor.run { f.model.followUpChecked = [:] }        // a relaunch
        await f.model.checkFollowUps()
        let states = await MainActor.run { f.model.needsYouData(inProject: f.project).followUps.map(\.state) }
        XCTAssertEqual(states, [.offered], "one card: the offer took the failure's place")
        let count = await MainActor.run { f.model.needsYouCount(inProject: f.project) }
        XCTAssertEqual(count, 1)
    }

    /// A deferred failure stays: you put it in Needs You to deal with.
    func testADeferredFailureStays() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        f.runner.reply = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-api-error.json"), errorOutput: "")
        try await offerAndAccept(f)
        await MainActor.run {
            let failed = f.model.followUpCard(forSession: f.session)!
            f.model.deferFollowUp(failed.id, projectID: f.project)
            f.model.followUpChecked = [:]
        }
        await f.model.checkFollowUps()
        let count = await MainActor.run { f.model.needsYouData(inProject: f.project).followUps.count }
        XCTAssertEqual(count, 2)
    }

    func testTwoQuickReviewsMakeOneCall() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        await MainActor.run {
            f.model.reviewSession(f.session)
            f.model.reviewSession(f.session)
        }
        try await waitUntil { await MainActor.run { f.model.followUpCard(forSession: f.session) != nil } }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "the second click came while the first was reading the history")
        let running = await MainActor.run { (f.model.assistantJobsRunning, f.model.assistantBackgroundProjects, f.model.reviewsStarting) }
        XCTAssertEqual(running.0, 0, "its slot is released")
        XCTAssertTrue(running.1.isEmpty)
        XCTAssertTrue(running.2.isEmpty)
    }

    func testAddToPlanKeepsWhatCouldntBeSaved() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant, lines: substantial, mark: true)
        try await offerAndAccept(f)
        await MainActor.run {
            let followUp = f.model.followUpCard(forSession: f.session)!
            assistant.saveError = CocoaError(.fileWriteOutOfSpace)
            f.model.addFollowUpPlanChanges(followUp.id, projectID: f.project)
            XCTAssertEqual(f.model.followUpCard(forSession: f.session)?.planChanges.count, 1, "left on the card to try again")
            XCTAssertEqual(f.model.toast?.text, "Added 0 of 1. The rest couldn't be saved.")
            assistant.saveError = nil
            f.model.addFollowUpPlanChanges(followUp.id, projectID: f.project)
            XCTAssertNil(f.model.followUpCard(forSession: f.session))
            XCTAssertEqual(f.model.items(inProject: f.project).count, 1)
        }
    }

    func testAddToPlanChecksItemsAgain() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        let item = try await MainActor.run { () -> PlanItem in
            let note = try XCTUnwrap(f.model.addNote("Panel height", author: .user, projectID: f.project, sessionID: nil))
            return try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project, title: "Remember Shell panel height"))
        }
        try await offerAndAccept(f)
        await MainActor.run {
            let followUp = f.model.followUpCard(forSession: f.session)!
            XCTAssertEqual(followUp.planChanges.map(\.kind), [.add, .done])
            f.model.setStatus(.idea, ofItem: item.id, projectID: f.project)
            f.model.deleteItem(item.id, projectID: f.project)        // gone before Add to Plan
            f.model.addFollowUpPlanChanges(followUp.id, projectID: f.project)
            XCTAssertEqual(f.model.items(inProject: f.project).map(\.title), ["Remember the Shell's scroll position"],
                           "the item that went is skipped, the new one is added")
            XCTAssertEqual(f.model.toast?.text, "Added 1 change to the plan")
        }
    }

    func testUntickingANoteThatCantBeRemovedKeepsItTicked() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant, lines: substantial, mark: true)
        try await offerAndAccept(f)
        await MainActor.run {
            let followUp = f.model.followUpCard(forSession: f.session)!
            assistant.saveError = CocoaError(.fileWriteOutOfSpace)
            f.model.toggleFollowUpNote(followUp.notes[0].id, in: followUp.id, projectID: f.project)
            XCTAssertTrue(f.model.followUpCard(forSession: f.session)!.notes[0].isKept, "still saved, so still ticked")
            assistant.saveError = nil
            f.model.toggleFollowUpNote(followUp.notes[0].id, in: followUp.id, projectID: f.project)
            XCTAssertEqual(f.model.notes(inProject: f.project).filter { $0.author == .assistant }.count, 1, "no duplicate")
        }
    }

    /// After /clear: a new conversation, a new file, read from its start.
    func testANewConversationIsReadFromItsStart() async throws {
        let f = try await makeFixture(lines: [History.prompt("old")], mark: true)
        let cleared = "d00dfeed-1111-2222-3333-444455556666"
        let history = f.history.deletingLastPathComponent().appendingPathComponent("\(cleared).jsonl")
        try (substantial.joined(separator: "\n") + "\n").write(to: history, atomically: true, encoding: .utf8)
        await MainActor.run {
            f.model.applyTestSessionChange(f.session) { $0.claudeSessionID = cleared }
            f.model.followUpDue.insert(f.session)
        }
        await f.model.checkFollowUps()
        let card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered)
    }

    /// The marks, Not Now and a failed turn go through `state.json`.
    func testFollowUpStateSurvivesSaving() throws {
        var session = Session(projectID: UUID(), name: "s", workingDirectory: "/code")
        session.followUpMark = FollowUpMark(conversationID: "c", offset: 120)
        session.followUpDeclined = FollowUpMark(conversationID: "c", offset: 400)
        session.lastTurnFailed = true
        let again = try JSONFileStore.decoder.decode(Session.self, from: JSONFileStore.encoder.encode(session))
        XCTAssertEqual(again.followUpMark, session.followUpMark)
        XCTAssertEqual(again.followUpDeclined, session.followUpDeclined)
        XCTAssertTrue(again.lastTurnFailed)
    }

    func testAFailedTurnThroughTheHooksThenAGoodOne() async throws {
        let f = try await makeFixture(lines: substantial, mark: true)
        let hookLog = f.history.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("h.log")
        func hook(_ object: [String: Any]) -> String { f.session.uuidString + "\t" + History.json(object) + "\n" }
        try hook(["hook_event_name": "StopFailure", "session_id": FollowUpModelTests.conversation, "error": "rate_limit"])
            .write(to: hookLog, atomically: true, encoding: .utf8)
        await MainActor.run {
            f.model.pollHookEvents()
            XCTAssertTrue(f.model.workspace.session(f.session)?.lastTurnFailed ?? false)
            XCTAssertNotNil(f.model.log.entries.last { $0.title == "Shell Height: its turn failed (rate_limit)" }, "logged")
        }
        await f.model.checkFollowUps()
        var card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertNil(card)
        let handle = try FileHandle(forWritingTo: hookLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(hook(["hook_event_name": "Stop", "session_id": FollowUpModelTests.conversation,
                                                "last_assistant_message": "Done."]).utf8))
        try handle.close()
        await MainActor.run { f.model.pollHookEvents() }
        await setTask("done", f)
        await f.model.checkFollowUps()
        card = await MainActor.run { f.model.followUpCard(forSession: f.session) }
        XCTAssertEqual(card?.state, .offered, "a turn that ended normally clears it")
    }

    /// The daily limit counts background calls (captured-note checks) and
    /// starts again the next day.
    func testTheDailyLimitIsCounted() async throws {
        let f = try await makeFixture(mark: true)
        try await MainActor.run {
            for index in 0..<AssistantAppSettings.defaultDailyJobLimit {
                let note = try XCTUnwrap(f.model.addNote("Note \(index)", author: .user, projectID: f.project, sessionID: nil))
                f.model.checkCapturedNote(note, projectID: f.project)
            }
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .paused("Daily limit of 20 reached"))
            let extra = try XCTUnwrap(f.model.addNote("One too many", author: .user, projectID: f.project, sessionID: nil))
            f.model.checkCapturedNote(extra, projectID: f.project)
        }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, AssistantAppSettings.defaultDailyJobLimit, "the 21st isn't made")
        await MainActor.run {
            f.model.dailyJobs = DailyJobCount(day: "2026-09-28", count: AssistantAppSettings.defaultDailyJobLimit)
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .run, "yesterday's count doesn't apply")
        }
    }

    func testASessionsSuggestionShowsWithTheAssistantOff() async throws {
        let f = try await makeFixture(mark: true)
        await MainActor.run {
            f.assistant.inbox = ["\(FollowUpModelTests.conversation)\t/code/app\tsuggest\t\(Data("x".utf8).base64EncodedString())"]
            f.model.pollAssistantInbox()
            f.model.setAssistantMode(.off, projectID: f.project)
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1, "the session was told you'd see it")
        }
    }

    /// Background calls: one at a time per project. Things you start never
    /// wait behind one.
    func testBackgroundWorkIsOnePerProject() async throws {
        let f = try await makeFixture(mark: true)
        let call = AssistantCall(job: "t", model: "haiku", systemPrompt: "", schema: "{}", input: "{}")
        await MainActor.run {
            f.model.runAssistantJob(call, projectID: f.project, subject: "a", isBackground: true) { _ in }
            f.model.runAssistantJob(call, projectID: f.project, subject: "b", key: "b", isBackground: true) { _ in }
            XCTAssertTrue(f.model.isAssistantJobQueued(key: "b"), "a second background call in the project waits")
            f.model.runAssistantJob(call, projectID: f.project, subject: "mine", key: "mine") { _ in }
            XCTAssertFalse(f.model.isAssistantJobQueued(key: "mine"), "yours runs beside it")
            XCTAssertEqual(f.model.assistantJobsRunning, 2)
        }
        await f.model.waitForAssistantJobs()
    }

    func testAQueuedJobWithTheSameKeyIsReplaced() async throws {
        let f = try await makeFixture(mark: true)
        let finished = await MainActor.run { Finished() }
        let call = AssistantCall(job: "t", model: "haiku", systemPrompt: "", schema: "{}", input: "{}")
        await MainActor.run {
            // One background call at a time per project: A runs, B waits and is replaced by B2.
            f.model.runAssistantJob(call, projectID: f.project, subject: "a", key: "a", isBackground: true) {
                _ in finished.names.append("a")
            }
            f.model.runAssistantJob(call, projectID: f.project, subject: "b", key: "b", isBackground: true) {
                _ in finished.names.append("b")
            }
            XCTAssertTrue(f.model.isAssistantJobQueued(key: "b"), "same project: it waits")
            f.model.runAssistantJob(call, projectID: f.project, subject: "b2", key: "b", isBackground: true) {
                _ in finished.names.append("b2")
            }
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
