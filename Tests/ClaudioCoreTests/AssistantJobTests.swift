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
        XCTAssertEqual(AssistantFailure.timedOut(seconds: 60).message,
                       "No answer came back within 60 seconds. Nothing was changed. If this keeps happening, check that Claude Code is signed in: run claude in a Shell.")

        let overBudget = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-over-budget.json"), errorOutput: "")
        XCTAssertEqual(AssistantReplyParser.parse(overBudget, timeout: 60, budget: 0.05), .failure(.overBudget(0.05)),
                       "error_max_budget_usd, with no result")
        XCTAssertEqual(AssistantFailure.overBudget(0.05).message,
                       "It went over its cost limit ($0.05 at API prices), so it was stopped. Nothing was changed.")
    }

    // MARK: - The command

    func testTheCommand() {
        let commands = AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/h.log")
        let note = ProjectNote(text: "- [ ] starts with a dash", author: .user, createdAt: Date())
        let call = PromoteCheck.request(note: note, items: []).call
        let launch = commands.assistant(call, in: "/runs", settingSources: "")
        XCTAssertEqual(launch.environment["CLAUDE_CODE_MAX_RETRIES"], "2", "a rejected key fails in seconds, not minutes")
        XCTAssertEqual(launch.timeout, 60, "the call's own timeout, not the runner's default")
        let args = launch.claudeArguments
        XCTAssertEqual(Array(args.prefix(3)), ["-p", "--model", "haiku"])
        for flag in ["--json-schema", "--system-prompt", "--tools", "--strict-mcp-config", "--no-session-persistence"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "", "no tools")
        XCTAssertEqual(args[args.firstIndex(of: "--settings")! + 1], #"{"disableAllHooks":true}"#)
        XCTAssertEqual(args[args.firstIndex(of: "--setting-sources")! + 1], "")
        XCTAssertEqual(args[args.firstIndex(of: "--max-budget-usd")! + 1], "0.05", "a runaway call is stopped")
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

        let request = PromoteCheck.request(note: note, items: items)
        XCTAssertEqual(request.refs, ["i1": height.id])
        func reply(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
        func suggestion(_ json: String, items: [PlanItem] = items, askedFor: Bool = false) throws -> NoteSuggestion? {
            PromoteCheck.suggestion(from: try reply(json), note: note, refs: request.refs, items: items, askedFor: askedFor)
        }
        let duplicate = #"{"kind":"bug","promote":false,"title":"x","duplicateOf":"i1","reason":"Same work."}"#
        XCTAssertEqual(try suggestion(duplicate), .attach(itemID: height.id, reason: "Same work."))
        XCTAssertEqual(try suggestion(#"{"kind":"bug","promote":true,"title":"","duplicateOf":"i9","reason":"Reads like a bug."}"#),
                       .promote(title: "The shell panel forgets its height", status: .planned, reason: "Reads like a bug."),
                       "an unknown ref is ignored, and a blank title comes from the note")
        XCTAssertEqual(try suggestion(#"{"kind":"idea","promote":true,"title":"Shell themes","duplicateOf":null,"reason":"An idea."}"#),
                       .promote(title: "Shell themes", status: .idea, reason: "An idea."))
        let fact = #"{"kind":"fact","promote":false,"title":"Fact","duplicateOf":null,"reason":"Worth keeping."}"#
        XCTAssertNil(try suggestion(fact), "nothing to suggest")
        XCTAssertEqual(try suggestion(fact, askedFor: true),
                       .promote(title: "Fact", status: .planned, reason: "Worth keeping."), "but Promote… was asked for")

        var finished = height
        finished.status = .done
        XCTAssertNil(try suggestion(duplicate, items: [done, finished]), "an item done since the call isn't suggested")
        XCTAssertNil(try suggestion(duplicate, items: [done]), "nor one deleted since")

        let input = try JSONDecoder().decode(JSONValue.self, from: Data(request.call.input.utf8))
        XCTAssertEqual(input["plan"], .array([.object(["ref": .string("i1"), "title": .string(height.title), "status": .string("planned")])]),
                       "the model sees refs, never ids")
    }

    func testRepliesArentMisreadAfterThePlanChanges() async throws {
        let f = try await MainActor.run { try makeFixture() }
        // The model answers "same work as i2": B, as the call numbered it.
        f.runner.reply = CommandResult(exitCode: 0, output: #"{"is_error":false,"structured_output":{"kind":"bug","promote":false,"title":"t","duplicateOf":"i2","reason":"Same work."}}"#,
                                       errorOutput: "")
        let (noteID, b) = try await MainActor.run { () -> (UUID, UUID) in
            var ids: [UUID] = []
            for text in ["A", "B", "C"] {
                let note = try XCTUnwrap(f.model.addNote(text, author: .user, projectID: f.project, sessionID: nil))
                ids.append(try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project)).id)
            }
            let note = try XCTUnwrap(f.model.addNote("Like B", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
            // Before the reply: A is done, so renumbering now would make i2 C.
            f.model.setStatus(.done, ofItem: ids[0], projectID: f.project)
            return (note.id, ids[1])
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertEqual(f.model.noteSuggestions[noteID], .attach(itemID: b, reason: "Same work."))
        }
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
        XCTAssertEqual(job.costUSD ?? 0, 0.004279, accuracy: 0.000001, "for step 4's Activity Log")
        XCTAssertNil(job.failure)
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
        let (promoted, deleted, linked) = try await MainActor.run { () -> (UUID, UUID, UUID) in
            let a = try XCTUnwrap(f.model.addNote("A", author: .user, projectID: f.project, sessionID: nil))
            let b = try XCTUnwrap(f.model.addNote("B", author: .user, projectID: f.project, sessionID: nil))
            let c = try XCTUnwrap(f.model.addNote("C", author: .user, projectID: f.project, sessionID: nil))
            for note in [a, b, c] { f.model.requestPromote(note.id, projectID: f.project) }
            // Before the replies arrive: A promoted by hand, B deleted, and C
            // given an item without its check being cleared (the reply's own
            // guard must catch it).
            f.model.promoteNote(a.id, projectID: f.project)
            f.model.deleteNote(b.id, projectID: f.project)
            var data = try XCTUnwrap(f.model.assistantData[f.project])
            let index = try XCTUnwrap(data.notes.firstIndex { $0.id == c.id })
            data.notes[index].itemID = f.model.items(inProject: f.project).first?.id
            f.model.assistantData[f.project] = data
            XCTAssertEqual(f.model.noteSuggestions[c.id], .checking)
            return (a.id, b.id, c.id)
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertNil(f.model.noteSuggestions[promoted])
            XCTAssertNil(f.model.noteSuggestions[deleted])
            XCTAssertNil(f.model.noteSuggestions[linked], "no spinner left behind")
            XCTAssertEqual(f.model.items(inProject: f.project).count, 1, "only the item made by hand")
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
            XCTAssertTrue(f.model.assistantJobTasks.isEmpty, "finished calls aren't held")
        }
    }

    func testPromoteTwiceDuringACheckMakesOneCall() async throws {
        let f = try await MainActor.run { try makeFixture() }
        f.runner.reply = try reply("assistant-promote-new.json")
        try await MainActor.run {
            let note = try XCTUnwrap(f.model.addNote("Once", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
            f.model.requestPromote(note.id, projectID: f.project)
        }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1)
    }

    func testCreditsAreDecidedBeforeTheThreshold() async throws {
        let f = try await MainActor.run { try makeFixture(auth: #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}"#) }
        await f.model.checkEnvironment(force: true)
        // A full 5-hour window with credits enabled: Claude Code is spending credits.
        f.runner.base.usageOutput = try Fixtures.string("usage-stream.jsonl").replacingOccurrences(of: #""percent":5"#, with: #""percent":100"#)
        await f.model.refreshUsage()
        await MainActor.run {
            XCTAssertEqual(f.model.usage?.current(at: AssistantJobTests.beforeReset).isUsingCredits, true)
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .paused("Using credits"))
            XCTAssertEqual(f.model.usageHighNote, "Using credits. Things you start still run.")
            var settings = f.model.settings
            settings.assistant.allowWhileUsingCredits = true
            f.model.updateSettings(settings)
            XCTAssertEqual(f.model.backgroundGate(forProject: f.project), .run, "allowed, even though the window is over the threshold")
            XCTAssertNil(f.model.usageHighNote)
        }
    }

    func testTheAuditRecordsAFailedCall() async throws {
        let assistant = MemoryAssistantStore()
        let runner = AssistantRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        runner.reply = CommandResult(exitCode: 1, output: try Fixtures.string("assistant-api-error.json"), errorOutput: "")
        let (model, project) = try await MainActor.run { () -> (AppModel, UUID) in
            let store = MemoryStore()
            let project = store.state.workspace.addProject(path: "/code/app")
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                                 assistantStore: assistant, locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
            let note = try XCTUnwrap(model.addNote("x", author: .user, projectID: project, sessionID: nil))
            model.requestPromote(note.id, projectID: project)
            return (model, project)
        }
        await model.waitForAssistantJobs()
        let job = try XCTUnwrap(assistant.audit[project]?.last?.job)
        XCTAssertFalse(job.succeeded)
        XCTAssertEqual(job.failure, AssistantFailure.apiError("Failed to authenticate. API Error: 401 API key is invalid.").message)
        XCTAssertNil(job.costUSD)
    }

    func testAnUnusableReplyIsLoggedByItsShapeNotItsContents() async throws {
        let f = try await MainActor.run { try makeFixture() }
        f.runner.reply = CommandResult(exitCode: 0, output: "Welcome from .zshrc {not json}\n" + #"{"type":"result","subtype":"success","is_error":false,"result":"The note: secret"}"#,
                                       errorOutput: "")
        try await MainActor.run {
            let note = try XCTUnwrap(f.model.addNote("secret", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            let entry = f.model.log.entries.first { $0.title == "Assistant: Promote check gave a reply Claudio couldn't use" }
            XCTAssertEqual(entry?.detail, "type: result · subtype: success · keys: is_error, result, subtype, type",
                           "the reply is found after the profile's line, and described without its text")
            XCTAssertEqual(f.model.errorMessage, AssistantFailure.invalidReply.message)
        }
    }

    func testAnErrorWithoutResultTextIsDescribedFromItsFields() {
        let noText = CommandResult(exitCode: 1, output: #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Tool failed"]}"#,
                                   errorOutput: "")
        XCTAssertEqual(AssistantReplyParser.parse(noText, timeout: 60), .failure(.apiError("Tool failed")))
        let bare = CommandResult(exitCode: 1, output: #"{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns"}"#,
                                 errorOutput: "")
        XCTAssertEqual(AssistantReplyParser.parse(bare, timeout: 60), .failure(.apiError("error_max_turns, max_turns")),
                       "never the raw output")
    }

    func testTheRunnerStopsACommandAtItsOwnTimeout() async {
        var launch = TerminalLaunch(executable: "/bin/sleep", arguments: ["5"], environment: [:], workingDirectory: "/", claudeArguments: [])
        launch.timeout = 0.3
        let started = Date()
        let result = await ProcessCommandRunner(timeout: 60).run(launch)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        let quick = await ProcessCommandRunner(timeout: 60).run(TerminalLaunch(executable: "/bin/sh", arguments: ["-c", "true"],
                                                                            environment: [:], workingDirectory: "/", claudeArguments: []))
        XCTAssertFalse(quick.timedOut)
    }

    func testADanglingItemLinkIsShownAndCanBeDetached() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let note = try XCTUnwrap(f.model.addNote("Orphan", author: .user, projectID: f.project, sessionID: nil))
            var data = try XCTUnwrap(f.model.assistantData[f.project])
            data.notes[0].itemID = UUID()   // an item kept unread, or removed by hand
            f.model.assistantData[f.project] = data
            let linked = try XCTUnwrap(f.model.notes(inProject: f.project).first)
            XCTAssertEqual(f.model.attachedItem(of: linked, inProject: f.project), .unreadable)
            f.model.detachNote(note.id, projectID: f.project)
            let freed = try XCTUnwrap(f.model.notes(inProject: f.project).first)
            XCTAssertEqual(f.model.attachedItem(of: freed, inProject: f.project), .none)
            XCTAssertNotNil(f.model.promoteNote(note.id, projectID: f.project), "and it can be promoted again")
        }
    }

    func testDeletingAnItemClearsSuggestionsToAttachToIt() async throws {
        let f = try await MainActor.run { try makeFixture() }
        f.runner.reply = try reply("assistant-promote-duplicate.json")
        let (noteID, itemID) = try await MainActor.run { () -> (UUID, UUID) in
            let first = try XCTUnwrap(f.model.addNote("Remember Shell panel height", author: .user, projectID: f.project, sessionID: nil))
            let item = try XCTUnwrap(f.model.promoteNote(first.id, projectID: f.project))
            let note = try XCTUnwrap(f.model.addNote("It forgets its height", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
            return (note.id, item.id)
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            guard case .attach? = f.model.noteSuggestions[noteID] else { return XCTFail("expected Attach") }
            f.model.deleteItem(itemID, projectID: f.project)
            XCTAssertNil(f.model.noteSuggestions[noteID], "nothing left to attach to")
            XCTAssertNotNil(f.model.promoteNote(noteID, projectID: f.project), "and it can still become an item")
        }
    }
}
