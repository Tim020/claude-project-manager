import XCTest
@testable import ClaudioCore

/// Answers assistant calls (`claude -p … --json-schema`) with canned output,
/// and everything else as `FakeRunner` does.
private final class AssistantRunner: CommandRunning, @unchecked Sendable {
    let base = FakeRunner()
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var reply = CommandResult(exitCode: 0, output: "", errorOutput: "")

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        let args = command.claudeArguments
        guard args.contains("--json-schema") else { return await base.run(command) }
        lock.withLock { _calls.append(args) }
        return reply
    }
}

final class AssistantJobTests: XCTestCase {
    /// Before the usage fixture's windows reset, so its figures count.
    static let beforeReset = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!

    private struct Fixture {
        let model: AppModel
        let runner: AssistantRunner
        let project: UUID
    }

    /// A model signed in to an API key by default (no usage reading
    /// expected), so background work runs unless a test says otherwise.
    @MainActor private func makeFixture(auth: String = #"{"loggedIn": true, "authMethod": "api_key"}"#) throws -> Fixture {
        let runner = AssistantRunner()
        runner.base.authOutput = auth
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                             locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil }, shell: "/bin/sh",
                             now: { AssistantJobTests.beforeReset }, home: "/")
        return Fixture(model: model, runner: runner, project: project)
    }

    private func reply(_ fixture: String) throws -> CommandResult {
        CommandResult(exitCode: 0, output: try Fixtures.string(fixture), errorOutput: "")
    }

    // MARK: - Reading replies

    func testRepliesAreParsedFromRecordedOutput() throws {
        guard case .success(let reply) = AssistantReplyParser.parse(try reply("assistant-promote-new.json"), timeout: 60) else {
            return XCTFail("expected a reply")
        }
        XCTAssertEqual(reply.output["title"]?.stringValue, "Fix Shell panel flicker on maximise")
        XCTAssertEqual(reply.costUSD ?? 0, 0.004279, accuracy: 0.000001)
        XCTAssertEqual(reply.durationMS, 6514)

        let signedOut = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-signed-out.json"), errorOutput: "")
        XCTAssertEqual(AssistantReplyParser.parse(signedOut, timeout: 60), .failure(.signedOut),
                       "is_error with \"subtype\": \"success\" is still a failure")
        let rejected = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-api-error.json"), errorOutput: "")
        XCTAssertEqual(AssistantReplyParser.parse(rejected, timeout: 60),
                       .failure(.apiError("Failed to authenticate. API Error: 401 API key is invalid.")))
        XCTAssertEqual(AssistantReplyParser.parse(CommandResult(exitCode: 15, output: "", errorOutput: "", timedOut: true), timeout: 60),
                       .failure(.timedOut(seconds: 60)))
        XCTAssertEqual(AssistantReplyParser.parse(CommandResult(exitCode: 0, output: "not json", errorOutput: ""), timeout: 60),
                       .failure(.invalidReply))
        XCTAssertEqual(AssistantReplyParser.parse(CommandResult(exitCode: 127, output: "", errorOutput: "claude: not found"), timeout: 60),
                       .failure(.failed("claude: not found")))
        XCTAssertEqual(AssistantReplyParser.parse(CommandResult(exitCode: 0, output: #"{"is_error":false,"result":"hi"}"#, errorOutput: ""),
                                                  timeout: 60),
                       .failure(.invalidReply), "no structured output")
        XCTAssertEqual(AssistantFailure.timedOut(seconds: 60).message, "No answer came back within 60 seconds. Nothing was changed.")
    }

    // MARK: - The command

    func testTheCommand() {
        let commands = AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/h.log")
        let note = ProjectNote(text: "- [ ] starts with a dash", author: .user, createdAt: Date())
        let call = PromoteCheck.call(note: note, items: [])
        let launch = commands.assistant(call, in: "/runs", settingSources: "")
        let args = launch.claudeArguments
        XCTAssertEqual(Array(args.prefix(3)), ["-p", "--model", "haiku"])
        for flag in ["--json-schema", "--system-prompt", "--tools", "--strict-mcp-config", "--no-session-persistence"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "", "no tools")
        XCTAssertEqual(args[args.firstIndex(of: "--settings")! + 1], #"{"disableAllHooks":true}"#)
        XCTAssertEqual(args[args.firstIndex(of: "--setting-sources")! + 1], "")
        XCTAssertEqual(args.suffix(2).first, "--", "the input goes last, after --")
        XCTAssertTrue(args.last?.contains("starts with a dash") == true)
        XCTAssertEqual(launch.workingDirectory, "/runs")
        XCTAssertEqual(launch.displayCommand, "claude -p (assistant: Promote check, Haiku)", "the log shows a label, not the prompt")
    }

    func testSettingSources() throws {
        func value(_ json: String) throws -> String {
            AssistantSettingSources.value(userSettings: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(AssistantSettingSources.value(userSettings: nil), "")
        XCTAssertEqual(try value(#"{"model":"opus","statusLine":{}}"#), "", "nothing sign-in needs")
        XCTAssertEqual(try value(#"{"apiKeyHelper":"~/bin/key"}"#), "user")
        XCTAssertEqual(try value(#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}"#), "user")
        XCTAssertEqual(try value(#"{"env":{"DEBUG":"1"}}"#), "")
    }

    // MARK: - Turning replies into suggestions

    func testSuggestionsTrustOnlyWhatCodeCanCheck() throws {
        let note = ProjectNote(text: "The shell panel forgets its height. Annoying.", author: .user, createdAt: Date())
        let height = PlanItem(title: "Remember Shell panel height per project", status: .planned, createdAt: Date())
        let done = PlanItem(title: "Shell panel", status: .done, createdAt: Date())
        let items = [done, height]
        XCTAssertEqual(PromoteCheck.refs(for: items).map(\.ref), ["i1"], "done items aren't offered")

        func reply(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
        XCTAssertEqual(PromoteCheck.suggestion(from: try reply(#"{"kind":"bug","promote":false,"title":"x","duplicateOf":"i1","reason":"Same work."}"#),
                                               note: note, items: items, askedFor: false),
                       .attach(itemID: height.id, reason: "Same work."))
        XCTAssertEqual(PromoteCheck.suggestion(from: try reply(#"{"kind":"bug","promote":true,"title":"","duplicateOf":"i9","reason":"Reads like a bug."}"#),
                                               note: note, items: items, askedFor: false),
                       .promote(title: "The shell panel forgets its height", status: .planned, reason: "Reads like a bug."),
                       "an unknown ref is ignored, and a blank title comes from the note")
        XCTAssertEqual(PromoteCheck.suggestion(from: try reply(#"{"kind":"idea","promote":true,"title":"Shell themes","duplicateOf":null,"reason":"An idea."}"#),
                                               note: note, items: items, askedFor: false),
                       .promote(title: "Shell themes", status: .idea, reason: "An idea."))
        let fact = try reply(#"{"kind":"fact","promote":false,"title":"Fact","duplicateOf":null,"reason":"Worth keeping."}"#)
        XCTAssertNil(PromoteCheck.suggestion(from: fact, note: note, items: items, askedFor: false), "nothing to suggest")
        XCTAssertEqual(PromoteCheck.suggestion(from: fact, note: note, items: items, askedFor: true),
                       .promote(title: "Fact", status: .planned, reason: "Worth keeping."), "but Promote… was asked for")

        let input = try JSONDecoder().decode(JSONValue.self, from: Data(PromoteCheck.call(note: note, items: items).input.utf8))
        XCTAssertEqual(input["plan"], .array([.object(["ref": .string("i1"), "title": .string(height.title), "status": .string("planned")])]),
                       "the model sees refs, never ids")
    }

    // MARK: - The model

    func testPromoteRunsTheCheckAndShowsWhatItSuggests() async throws {
        let f = try await MainActor.run { try makeFixture() }
        f.runner.reply = try reply("assistant-promote-duplicate.json")
        let noteID = try await MainActor.run { () -> UUID in
            let first = try XCTUnwrap(f.model.addNote("Remember Shell panel height per project", author: .user, projectID: f.project, sessionID: nil))
            f.model.promoteNote(first.id, projectID: f.project)
            let note = try XCTUnwrap(f.model.addNote("The shell panel forgets how tall it was after a relaunch.", author: .user,
                                                     projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
            XCTAssertEqual(f.model.noteSuggestions[note.id], .checking)
            return note.id
        }
        await f.model.waitForAssistantJobs()
        try await MainActor.run {
            let item = try XCTUnwrap(f.model.items(inProject: f.project).first)
            guard case .attach(let itemID, _)? = f.model.noteSuggestions[noteID] else { return XCTFail("expected Attach") }
            XCTAssertEqual(itemID, item.id)
            XCTAssertEqual(f.model.items(inProject: f.project).count, 1, "a reply never changes the plan by itself")
            XCTAssertTrue(f.model.log.entries.contains { $0.title == "Assistant: Promote check (Haiku, 5.3 s)" })
            XCTAssertTrue(f.model.log.entries.contains { $0.title == "claude -p (assistant: Promote check, Haiku)" })

            XCTAssertTrue(f.model.attachNote(noteID, to: itemID, projectID: f.project))
            XCTAssertNil(f.model.noteSuggestions[noteID], "answered")
        }
    }

    func testTheAuditRecordsEachCall() async throws {
        let assistant = MemoryAssistantStore()
        let runner = AssistantRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        runner.reply = try reply("assistant-promote-new.json")
        let (model, project) = try await MainActor.run { () -> (AppModel, UUID) in
            let store = MemoryStore()
            let project = store.state.workspace.addProject(path: "/code/app")
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                                 assistantStore: assistant, locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
            let note = try XCTUnwrap(model.addNote("Flicker", author: .user, projectID: project, sessionID: nil))
            model.requestPromote(note.id, projectID: project)
            return (model, project)
        }
        await model.waitForAssistantJobs()
        let job = try XCTUnwrap(assistant.audit[project]?.last?.job)
        XCTAssertEqual(assistant.audit[project]?.last?.action, .jobRan)
        XCTAssertEqual(job.name, "Promote check")
        XCTAssertEqual(job.model, "Haiku")
        XCTAssertTrue(job.succeeded)
        XCTAssertEqual(job.durationMS, 6514)
    }

    func testAFailureYouAskedForIsShownAndABackgroundOneIsNot() async throws {
        let f = try await MainActor.run { try makeFixture() }
        await f.model.checkEnvironment(force: true)
        f.runner.reply = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-signed-out.json"), errorOutput: "")
        let noteID = try await MainActor.run { () -> UUID in
            f.model.beginNoteCapture()
            f.model.updateNoteDraft("Background")
            _ = try XCTUnwrap(f.model.saveNoteCapture())
            let note = try XCTUnwrap(f.model.addNote("Asked for", author: .user, projectID: f.project, sessionID: nil))
            return note.id
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertEqual(f.runner.calls.count, 1, "the captured note was checked")
            XCTAssertNil(f.model.errorMessage, "a background failure only goes in the log")
            f.model.requestPromote(noteID, projectID: f.project)
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertEqual(f.model.errorMessage, AssistantFailure.signedOut.message)
            XCTAssertNil(f.model.noteSuggestions[noteID], "no suggestion left spinning")
        }
    }

    func testAResultForANoteThatMovedOnIsDropped() async throws {
        let f = try await MainActor.run { try makeFixture() }
        f.runner.reply = try reply("assistant-promote-new.json")
        let (promoted, deleted) = try await MainActor.run { () -> (UUID, UUID) in
            let a = try XCTUnwrap(f.model.addNote("A", author: .user, projectID: f.project, sessionID: nil))
            let b = try XCTUnwrap(f.model.addNote("B", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(a.id, projectID: f.project)
            f.model.requestPromote(b.id, projectID: f.project)
            // Before the replies arrive: A promoted by hand, B deleted.
            f.model.promoteNote(a.id, projectID: f.project)
            f.model.deleteNote(b.id, projectID: f.project)
            return (a.id, b.id)
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertNil(f.model.noteSuggestions[promoted])
            XCTAssertNil(f.model.noteSuggestions[deleted])
        }
    }

    func testWithTheAssistantOffPromoteMakesAnIdeaWithoutACall() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.setAssistantMode(.off, projectID: f.project)
            let note = try XCTUnwrap(f.model.addNote("Maybe themes?", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
            XCTAssertEqual(f.model.items(inProject: f.project).map(\.status), [.idea])
            XCTAssertEqual(f.model.toast?.text, "Added to Plan as an Idea")
            XCTAssertEqual(f.runner.calls, [])

            var settings = f.model.settings
            settings.assistant.isEnabled = false
            f.model.updateSettings(settings)
            f.model.setAssistantMode(.automatic, projectID: f.project)
            XCTAssertFalse(f.model.isAssistantOn(inProject: f.project), "the app switch turns it off everywhere")
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .off)
        }
    }

    // MARK: - The gate

    func testTheGate() async throws {
        // A claude.ai plan: a reading is expected.
        let f = try await MainActor.run { try makeFixture(auth: #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}"#) }
        await f.model.checkEnvironment(force: true)
        await MainActor.run {
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .waitingForUsage, "no reading yet")
            f.model.setAssistantMode(.manual, projectID: f.project)
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .manual)
            f.model.setAssistantMode(.automatic, projectID: f.project)
        }
        // The fixture: 5-hour 5%, weekly 42%.
        f.runner.base.usageOutput = try Fixtures.string("usage-stream.jsonl")
        await f.model.refreshUsage()
        await MainActor.run {
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .run)
            XCTAssertNil(f.model.usageHighNote)
            var settings = f.model.settings
            settings.assistant.pauseThreshold = 40
            f.model.updateSettings(settings)
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .paused("Weekly usage 42%"))
            XCTAssertEqual(f.model.usageHighNote, "Weekly usage is 42%. Things you start still run.")
        }
        f.runner.base.usageOutput = try Fixtures.string("usage-stream.jsonl").replacingOccurrences(of: #""percent":5"#, with: #""percent":84"#)
        await f.model.refreshUsage()
        await MainActor.run {
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .paused("5-hour usage 84%"), "either window pauses it")
        }
    }

    func testAPausedCaptureIsNotCheckedButPromoteStillRuns() async throws {
        let f = try await MainActor.run { try makeFixture(auth: #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}"#) }
        await f.model.checkEnvironment(force: true)
        f.runner.base.usageOutput = try Fixtures.string("usage-stream.jsonl").replacingOccurrences(of: #""percent":5"#, with: #""percent":90"#)
        await f.model.refreshUsage()
        f.runner.reply = try reply("assistant-promote-new.json")
        let noteID = try await MainActor.run { () -> UUID in
            f.model.beginNoteCapture()
            f.model.updateNoteDraft("Flicker when maximised")
            let note = try XCTUnwrap(f.model.saveNoteCapture())
            XCTAssertNil(f.model.noteSuggestions[note.id], "skipped, not queued: the note keeps Promote…")
            f.model.requestPromote(note.id, projectID: f.project)
            return note.id
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertEqual(f.runner.calls.count, 1, "only the one you asked for")
            guard case .promote? = f.model.noteSuggestions[noteID] else { return XCTFail("expected Promote") }
        }
    }

    func testAtMostTwoCallsRunAtOnce() async throws {
        let f = try await MainActor.run { try makeFixture() }
        f.runner.reply = try reply("assistant-promote-new.json")
        try await MainActor.run {
            for text in ["A", "B", "C"] {
                let note = try XCTUnwrap(f.model.addNote(text, author: .user, projectID: f.project, sessionID: nil))
                f.model.requestPromote(note.id, projectID: f.project)
            }
            XCTAssertEqual(f.model.assistantJobsRunning, 2)
            XCTAssertEqual(f.model.assistantJobQueue.count, 1, "the third waits for a slot")
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertEqual(f.runner.calls.count, 3)
            XCTAssertEqual(f.model.assistantJobsRunning, 0)
        }
    }
}
