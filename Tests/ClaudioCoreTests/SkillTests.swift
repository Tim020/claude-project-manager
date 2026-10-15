import XCTest
@testable import ClaudioCore

/// Answers assistant calls with whatever `answer` gives for their arguments,
/// and everything else as `FakeRunner` does.
final class SkillRunner: CommandRunning, @unchecked Sendable {
    let base = FakeRunner()
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _scripts: [String] = []
    private var _answer: ([String]) -> CommandResult = { _ in CommandResult(exitCode: 1, output: "", errorOutput: "no answer set") }
    /// What a shell script (the login shell's PATH read) prints.
    var scriptOutput = CommandResult(exitCode: 0, output: "", errorOutput: "")

    var calls: [[String]] { lock.withLock { _calls } }
    /// Shell scripts run (not `claude`): their command lines.
    var scripts: [String] { lock.withLock { _scripts } }
    var answer: ([String]) -> CommandResult {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        let args = command.claudeArguments
        if args.isEmpty, let script = command.arguments.last {
            lock.withLock { _scripts.append(script) }
            return lock.withLock { scriptOutput }
        }
        guard args.contains("--json-schema") else { return await base.run(command) }
        lock.withLock { _calls.append(args) }
        return answer(args)
    }

    /// A successful call's output, with `output` as its structured reply.
    static func reply(_ output: String, cost: Double = 0.02) -> CommandResult {
        CommandResult(exitCode: 0, output: #"{"type":"result","subtype":"success","is_error":false,"duration_ms":4000,"total_cost_usd":\#(cost),"structured_output":\#(output)}"#,
                      errorOutput: "")
    }
}

/// Step 5: skills. Usage, chips, skill files, and Check Failed on notes.
final class SkillTests: XCTestCase {
    static let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
    static let conversation = "c0ffee00-1111-2222-3333-444455556666"

    struct Fixture {
        let model: AppModel
        let runner: SkillRunner
        let assistant: MemoryAssistantStore
        let project: UUID
        let session: UUID
        let claudeHome: URL
        let history: URL
        let hookLog: URL
    }

    /// A project at `/code/app` with one Completed session and its history
    /// file, signed in with an API key (so the gate needs no usage reading).
    func makeFixture(assistant: MemoryAssistantStore = MemoryAssistantStore(), lines: [String] = [History.prompt("Start")],
                     projectPath: String = "/code/app",
                     clock: @escaping () -> Date = { SkillTests.now }) async throws -> Fixture {
        let runner = SkillRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        let claudeHome = try makeTemporaryDirectory()
        let directory = claudeHome.appendingPathComponent("projects").appendingPathComponent(SessionDiscovery.directoryName(forProjectPath: projectPath))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("\(SkillTests.conversation).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: history, atomically: true, encoding: .utf8)
        var state = PersistedState()
        let project = state.workspace.addProject(path: projectPath)
        let session = Session(projectID: project, claudeSessionID: SkillTests.conversation, hasConversation: true, name: "Shell Height",
                              workingDirectory: projectPath, status: .completed, lastActivity: SkillTests.now.addingTimeInterval(-600))
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let hookLog = claudeHome.appendingPathComponent("h.log")
        let model = await MainActor.run {
            AppModel(store: store, discovery: SessionDiscovery(claudeHome: claudeHome), hookEventsURL: hookLog, runner: runner,
                     assistantStore: assistant, locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil },
                     shell: "/bin/sh", now: clock, home: "/")
        }
        await model.checkEnvironment(force: true)
        return Fixture(model: model, runner: runner, assistant: assistant, project: project, session: session.id,
                       claudeHome: claudeHome, history: history, hookLog: hookLog)
    }

    /// Hook lines for the session, as `HookSettings`' command writes them.
    func writeHooks(_ events: [[String: Any]], _ f: Fixture) throws {
        let text = events.map { f.session.uuidString + "\t" + History.json($0) }.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: f.hookLog) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: f.hookLog, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Usage

    func testSkillUseIsReadFromRecordedHooks() throws {
        let events = try Fixtures.lines("hook-skill-use.log").compactMap(HookEventParser.parse)
        XCTAssertEqual(events.map(\.name), [.userPromptSubmit, .userPromptSubmit, .preToolUse, .postToolUse])
        XCTAssertEqual(events.map(SkillUseDetector.skill(in:)), ["real-skill", nil, "linked-skill", nil],
                       "a typed /name is a use, and so is Claude calling the Skill tool; a plain prompt and PostToolUse aren't")
        var plugin = HookEvent(appSessionID: UUID(), name: .preToolUse)
        plugin.toolName = "Skill"
        plugin.toolInput = ["skill": .string("claudio:note")]
        XCTAssertNil(SkillUseDetector.skill(in: plugin), "a plugin's skill isn't the project's")
        var withArguments = HookEvent(appSessionID: UUID(), name: .userPromptSubmit)
        withArguments.prompt = "/readme-style check the intro"
        XCTAssertEqual(SkillUseDetector.skill(in: withArguments), "readme-style")
    }

    func testUsageIsSavedOncePerSessionAndDay() {
        var data = SkillsData()
        let session = UUID(), other = UUID()
        XCTAssertTrue(data.recordUse(of: "a", by: session, at: SkillTests.now))
        XCTAssertFalse(data.recordUse(of: "a", by: session, at: SkillTests.now.addingTimeInterval(60)), "same session, same day")
        XCTAssertTrue(data.recordUse(of: "a", by: other, at: SkillTests.now.addingTimeInterval(120)), "a new session")
        XCTAssertTrue(data.recordUse(of: "a", by: session, at: SkillTests.now.addingTimeInterval(86_400)), "a new day")
        XCTAssertEqual(data.usage["a"]?.sessions, [session, other])
        XCTAssertEqual(data.usage["a"]?.lastUsed, SkillTests.now.addingTimeInterval(86_400))
    }

    func testHookEventsCountUseOfTheProjectsSkills() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        await MainActor.run {
            assistant.skills[f.project] = [ApprovedSkill(name: "real-skill")]
            f.model.refreshApprovedSkills(projectID: f.project)
        }
        try writeHooks([
            ["hook_event_name": "UserPromptSubmit", "session_id": SkillTests.conversation, "prompt": "/real-skill"],
            ["hook_event_name": "PreToolUse", "session_id": SkillTests.conversation, "tool_name": "Skill", "tool_input": ["skill": "debug"]],
            ["hook_event_name": "PreToolUse", "session_id": SkillTests.conversation, "tool_name": "Skill", "tool_input": ["skill": "real-skill"]],
        ], f)
        await MainActor.run {
            f.model.pollHookEvents()
            let usage = f.model.skillsData(inProject: f.project).usage
            XCTAssertEqual(Array(usage.keys), ["real-skill"], "Claude Code's own skills aren't counted")
            XCTAssertEqual(usage["real-skill"]?.sessions, [f.session])
            XCTAssertEqual(usage["real-skill"]?.lastUsed, SkillTests.now)
            XCTAssertEqual(assistant.skillsData[f.project], f.model.skillsData(inProject: f.project), "saved")
        }
    }

    func testAnUnreadableSkillsFileIsLeftAlone() async throws {
        let assistant = MemoryAssistantStore()
        assistant.skillsDataError = CocoaError(.fileReadCorruptFile)
        let f = try await makeFixture(assistant: assistant)
        await MainActor.run {
            assistant.skills[f.project] = [ApprovedSkill(name: "real-skill")]
            f.model.refreshApprovedSkills(projectID: f.project)
            XCTAssertTrue(f.model.unreadableSkillsData.contains(f.project))
            XCTAssertTrue(f.model.log.entries.contains { $0.title.hasPrefix("Couldn't read the assistant's skills file") })
        }
        try writeHooks([["hook_event_name": "UserPromptSubmit", "session_id": SkillTests.conversation, "prompt": "/real-skill"]], f)
        await MainActor.run {
            f.model.pollHookEvents()
            XCTAssertNil(assistant.skillsData[f.project], "nothing written over it")
        }
    }

    func testSkillsDataKeepsWhatItCantRead() throws {
        let json = #"{"usage":{"good":{"sessions":["6F9619FF-8B86-D011-B42D-00C04FC964FF"],"lastUsed":"2026-10-01T10:00:00Z"},"bad":7}}"#
        let data = try JSONFileStore.decoder.decode(SkillsData.self, from: Data(json.utf8))
        XCTAssertEqual(data.usage["good"]?.sessions.count, 1)
        XCTAssertEqual(data.unreadableUsage["bad"], .number(7))
        let again = try JSONFileStore.decoder.decode(SkillsData.self, from: JSONFileStore.encoder.encode(data))
        XCTAssertEqual(again, data, "written back as it was")
    }

    // MARK: - Chips

    /// An Edit result line, as Claude Code writes it to the history.
    static func editResult(_ path: String) -> String {
        History.json(["type": "user", "cwd": "/code/app", "timestamp": "2026-10-05T11:00:00Z",
                      "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]],
                      "toolUseResult": ["filePath": path, "oldString": "a", "newString": "b", "originalFile": "a",
                                        "structuredPatch": [] as [Any]]])
    }

    func testChipsUseTheFilesInTheSessionsHistory() async throws {
        let f = try await makeFixture(lines: [History.prompt("Fix it"), SkillTests.editResult("/code/app/Sources/Claudio/ShellPanelViews.swift")])
        let item = try await MainActor.run { () -> PlanItem in
            f.assistant.skills[f.project] = [ApprovedSkill(name: "shell-map", paths: ["Sources/**/Shell*.swift"]),
                                             ApprovedSkill(name: "readme-style", paths: ["README.md"])]
            f.model.refreshApprovedSkills(projectID: f.project)
            let note = try XCTUnwrap(f.model.addNote("Shell", author: .session, projectID: f.project, sessionID: f.session))
            let item = try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project, title: "Shell"))
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project), [],
                           "nothing known yet: Files Changed never loaded")
            return item
        }
        await f.model.refreshTouchedFiles(forItem: item, inProject: f.project)
        await MainActor.run {
            XCTAssertEqual(f.model.itemTouchedFiles[item.id], ["Sources/Claudio/ShellPanelViews.swift"])
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project), ["shell-map"])
        }
    }

    func testChipsCountUseBySessionsInTheChosenFolder() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            f.assistant.skills[f.project] = [ApprovedSkill(name: "used-here")]
            f.model.refreshApprovedSkills(projectID: f.project)
            let folder = try XCTUnwrap(f.model.createFolder(in: f.project, containing: f.session))
            f.model.updateSkillsData(f.project) { _ = $0.recordUse(of: "used-here", by: f.session, at: SkillTests.now) }
            let item = PlanItem(title: "Next", status: .planned, createdAt: SkillTests.now)
            XCTAssertEqual(f.model.skillUsage(inProject: f.project, folderID: folder), ["used-here": 1])
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project, folderID: folder), ["used-here"])
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project, folderID: nil), [],
                           "used in another folder, so it doesn't count for Unfiled")
        }
    }

    // MARK: - Skill files

    func testSkillFilesThatCantBeUsedAreReported() throws {
        let root = try makeTemporaryDirectory()
        let skills = root.appendingPathComponent(".claude/skills")
        func write(_ name: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: skills.appendingPathComponent(name), withIntermediateDirectories: true)
            try text.write(to: skills.appendingPathComponent(name).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try write("good", "---\nname: good\ndescription: Fine.\nmetadata:\n  claudio-version: 3\n---\nBody\n")
        try write("open-ended", "---\nname: never-closed\ndescription: oops\nBody\n")
        try FileManager.default.createDirectory(at: skills.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let scan = SkillFiles.scan(inRoot: root)
        XCTAssertEqual(scan.skills.map(\.name), ["good", "open-ended"],
                       "one with no closing --- is still listed, under its folder's name")
        XCTAssertEqual(scan.skills.first?.version, 3)
        XCTAssertEqual(scan.problems, ["empty has no SKILL.md, so it isn't a skill",
                                       "open-ended/SKILL.md has no closing --- after its frontmatter, so its name and description can't be read"])
    }

    func testSkillFileProblemsAreLoggedOnce() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        await MainActor.run {
            assistant.skillProblems[f.project] = ["empty has no SKILL.md, so it isn't a skill"]
            f.model.refreshApprovedSkills(projectID: f.project)
            f.model.refreshApprovedSkills(projectID: f.project)
            let logged = f.model.log.entries.filter { $0.title.contains("approved skill files") }
            XCTAssertEqual(logged.count, 1, "not again on every rescan")
            XCTAssertEqual(logged.first?.detail, "empty has no SKILL.md, so it isn't a skill")
            assistant.skillProblems[f.project] = []
            f.model.refreshApprovedSkills(projectID: f.project)
            assistant.skillProblems[f.project] = ["empty has no SKILL.md, so it isn't a skill"]
            f.model.refreshApprovedSkills(projectID: f.project)
            XCTAssertEqual(f.model.log.entries.filter { $0.title.contains("approved skill files") }.count, 2,
                           "logged again once it comes back")
        }
    }

    // MARK: - Check Failed on a note

    func testABackgroundCheckThatFailsMarksTheNote() async throws {
        let f = try await makeFixture()
        f.runner.answer = { _ in CommandResult(exitCode: 1, output: (try? Fixtures.string("assistant-signed-out.json")) ?? "", errorOutput: "") }
        let noteID = try await MainActor.run { () -> UUID in
            f.model.beginNoteCapture()
            f.model.updateNoteDraft("The shell panel flickers")
            return try XCTUnwrap(f.model.saveNoteCapture()).id
        }
        await f.model.waitForAssistantJobs()
        try await MainActor.run {
            let failure = try XCTUnwrap(f.model.noteCheckFailure(noteID, inProject: f.project))
            XCTAssertEqual(failure.message, AssistantFailure.signedOut.message)
            XCTAssertEqual(failure.model, "Haiku")
            f.model.openNoteCheckFailure(noteID, projectID: f.project)
            guard case .jobFailed(let project, let row) = f.model.assistantPanel else { return XCTFail("Job Failed opens") }
            XCTAssertEqual(project, f.project)
            XCTAssertEqual(row.job, PromoteCheck.job)
            XCTAssertEqual(row.retry, .noteCheck(noteID: noteID))
            f.runner.answer = { _ in (try? CommandResult(exitCode: 0, output: Fixtures.string("assistant-promote-new.json"), errorOutput: ""))! }
            XCTAssertTrue(f.model.retry(.noteCheck(noteID: noteID), projectID: f.project))
            XCTAssertNil(f.model.noteCheckFailure(noteID, inProject: f.project), "checking again clears it")
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertNil(f.model.noteCheckFailure(noteID, inProject: f.project))
            XCTAssertNotNil(f.model.noteSuggestions[noteID])
        }
    }

    func testACheckYouAskedForDoesntMarkTheNote() async throws {
        let f = try await makeFixture()
        f.runner.answer = { _ in CommandResult(exitCode: 1, output: (try? Fixtures.string("assistant-signed-out.json")) ?? "", errorOutput: "") }
        let noteID = try await MainActor.run { () -> UUID in
            let note = try XCTUnwrap(f.model.addNote("Asked", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
            return note.id
        }
        await f.model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertNil(f.model.noteCheckFailure(noteID, inProject: f.project), "the error was shown instead")
            XCTAssertEqual(f.model.errorMessage, AssistantFailure.signedOut.message)
        }
    }

    func testAFailedNoteThatJoinsThePlanLosesItsMarker() async throws {
        let f = try await makeFixture()
        f.runner.answer = { _ in CommandResult(exitCode: 1, output: (try? Fixtures.string("assistant-signed-out.json")) ?? "", errorOutput: "") }
        let noteID = try await MainActor.run { () -> UUID in
            f.model.beginNoteCapture()
            f.model.updateNoteDraft("Flicker")
            return try XCTUnwrap(f.model.saveNoteCapture()).id
        }
        await f.model.waitForAssistantJobs()
        try await MainActor.run {
            XCTAssertNotNil(f.model.noteCheckFailure(noteID, inProject: f.project))
            _ = try XCTUnwrap(f.model.promoteNote(noteID, projectID: f.project, title: "Flicker"))
            XCTAssertNil(f.model.noteCheckFailure(noteID, inProject: f.project))
        }
    }

    // MARK: - Lessons to drafts

    static let draftReply = #"{"action":"new","skill":null,"name":"linux-tests","description":"Run the tests on Linux before pushing.","whenToUse":"","paths":[],"body":"Run the Linux tests in Docker before you push.","why":"stops failing CI runs"}"#

    /// Answers follow-ups with one lesson citing f1, and drafts with `draft`.
    func answerFollowUpsAndDrafts(_ f: Fixture, draft: String = SkillTests.draftReply, remember: Bool = false) {
        let followUp = #"{"notes":[],"planChanges":[],"lessons":[{"summary":"Run the Linux script, not swift test.","evidence":["f1","c1"],"remember":\#(remember)}]}"#
        f.runner.answer = { args in
            args.contains { $0.contains("\"lessons\"") } ? SkillRunner.reply(followUp) : SkillRunner.reply(draft, cost: 0.03)
        }
    }

    /// What a session did: a failing `swift test` and a correction.
    static func digest(remember: Bool = false) -> SessionDigest {
        SessionDigest.build(lines: [
            History.prompt("Fix the shell height"),
            History.tool("t1", "Bash", ["command": "swift test --filter ShellPanelTests"]),
            History.result("t1", "Exit code 1\nerror: 2 tests failed", error: true),
            History.prompt(remember ? "No, remember to use the Linux script next time" : "No, use the Linux script instead"),
        ], projectPath: "/code/app")
    }

    /// A second session in the project, for the lesson's second sighting.
    @MainActor func addSession(_ f: Fixture, name: String = "Shell Width") -> UUID {
        let session = Session(projectID: f.project, claudeSessionID: UUID().uuidString.lowercased(), hasConversation: true, name: name,
                              workingDirectory: "/code/app", status: .completed)
        f.model.applyTestSession(session)
        return session.id
    }

    /// A follow-up for the session, run as if accepted.
    func followUp(_ f: Fixture, session: UUID, remember: Bool = false) async {
        await MainActor.run {
            f.model.startFollowUp(session, digest: SkillTests.digest(remember: remember),
                                  mark: FollowUpMark(conversationID: "c", offset: 0), askedFor: true)
        }
        await f.model.waitForSkillDrafts()
    }

    func testALessonSeenInTwoSessionsIsDraftedInTheBackground() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        try await MainActor.run {
            let candidate = try XCTUnwrap(f.model.skillsData(inProject: f.project).candidates.first)
            XCTAssertEqual(candidate.sessionCount, 1)
            XCTAssertEqual(candidate.signature, "bash swift test | error: # tests failed")
            XCTAssertEqual(candidate.evidence.map(\.kind), [.failure, .correction])
            XCTAssertEqual(f.assistant.skillsData[f.project]?.candidates.count, 1, "saved")
        }
        XCTAssertEqual(f.runner.calls.count, 1, "seen once: no draft")
        let second = await MainActor.run { addSession(f) }
        await followUp(f, session: second)
        XCTAssertEqual(f.runner.calls.count, 3, "the second sighting drafts a skill")
        XCTAssertTrue(f.runner.calls[2].containsSequence(["--model", "sonnet"]))
        try await MainActor.run {
            let proposal = try XCTUnwrap(f.model.skillProposals(inProject: f.project).first)
            XCTAssertEqual(proposal.name, "linux-tests")
            XCTAssertFalse(proposal.isChange)
            XCTAssertEqual(proposal.why, "Stops failing CI runs.")
            XCTAssertEqual(proposal.model, "Sonnet")
            let skill = SkillFiles.skill(fromSkillFile: proposal.text, folderName: "x")
            XCTAssertEqual(skill.version, 1)
            XCTAssertNotNil(skill.claudioID)
            XCTAssertTrue(proposal.text.contains("claudio-evidence: "), "the sessions it came from")
            XCTAssertEqual(f.model.skillsData(inProject: f.project).candidates.first?.state, .proposed)
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 3, "two follow-ups and the new skill")
            XCTAssertEqual(f.model.backgroundJobsToday, 1, "the draft counts as background work")
            XCTAssertEqual(f.assistant.audit[f.project]?.last?.job?.name, SkillDraftJob.job)
        }
    }

    func testManualModeOffersTheDraft() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            f.model.commandExistsOverride = { _ in true }
            f.model.setAssistantMode(.manual, projectID: f.project)
        }
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        let second = await MainActor.run { addSession(f) }
        await followUp(f, session: second)
        XCTAssertEqual(f.runner.calls.count, 2, "no draft without asking")
        let offer = try await MainActor.run { () -> LessonCandidate in
            let offer = try XCTUnwrap(f.model.skillOffers(inProject: f.project).first)
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 3, "two follow-ups and the offer")
            f.model.acceptSkillOffer(offer.id, projectID: f.project)
            return offer
        }
        await f.model.waitForSkillDrafts()
        XCTAssertEqual(f.runner.calls.count, 3)
        await MainActor.run {
            XCTAssertEqual(f.model.skillProposals(inProject: f.project).count, 1)
            XCTAssertEqual(f.model.skillCandidate(offer.id, inProject: f.project)?.state, .proposed)
            XCTAssertEqual(f.model.backgroundJobsToday, 0, "you asked for it")
        }
    }

    func testNotNowOnAnOfferWaitsForTwoMoreSessions() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.setAssistantMode(.manual, projectID: f.project) }
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        let second = await MainActor.run { addSession(f) }
        await followUp(f, session: second)
        try await MainActor.run {
            let offer = try XCTUnwrap(f.model.skillOffers(inProject: f.project).first)
            f.model.declineSkillOffer(offer.id, projectID: f.project)
            XCTAssertTrue(f.model.skillOffers(inProject: f.project).isEmpty)
            XCTAssertEqual(f.model.skillCandidate(offer.id, inProject: f.project)?.heldUntilSessions, 4)
        }
        let third = await MainActor.run { addSession(f, name: "Third") }
        await followUp(f, session: third)
        await MainActor.run { XCTAssertTrue(f.model.skillOffers(inProject: f.project).isEmpty, "three sessions: not yet") }
        let fourth = await MainActor.run { addSession(f, name: "Fourth") }
        await followUp(f, session: fourth)
        await MainActor.run { XCTAssertEqual(f.model.skillOffers(inProject: f.project).count, 1, "offered again at four") }
    }

    func testRememberThisIsDraftedStraightAway() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            f.model.commandExistsOverride = { _ in true }
            f.model.setAssistantMode(.manual, projectID: f.project)
        }
        answerFollowUpsAndDrafts(f, remember: true)
        await followUp(f, session: f.session, remember: true)
        XCTAssertEqual(f.runner.calls.count, 2, "one session, but you said to remember it")
        await MainActor.run {
            XCTAssertEqual(f.model.skillProposals(inProject: f.project).count, 1)
            XCTAssertEqual(f.model.skillsData(inProject: f.project).candidates.first?.remember, false, "drafted once")
        }
    }

    func testTheModelCantClaimRememberThis() async throws {
        let f = try await makeFixture()
        answerFollowUpsAndDrafts(f, remember: true)
        await followUp(f, session: f.session, remember: false)
        XCTAssertEqual(f.runner.calls.count, 1, "no correction asked for it, so it waits for a second session")
    }

    func testAHeldDraftBecomesAnOfferInManualAndGoesInOff() async throws {
        let f = try await makeFixture()
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        await MainActor.run {
            f.model.dailyJobs = DailyJobCount(day: DailyJobCount.day(of: SkillTests.now), count: f.model.settings.assistant.dailyJobLimit)
        }
        let second = await MainActor.run { addSession(f) }
        await followUp(f, session: second)
        await MainActor.run {
            XCTAssertEqual(f.model.heldJobs.map(\.job), [SkillDraftJob.job], "held at the daily limit")
            XCTAssertTrue(f.model.heldJobs[0].reason.hasPrefix("Daily limit"))
            XCTAssertFalse(f.model.log.entries.contains { ($0.detail ?? "").contains("Linux script") }, "logged by id, not words")
            f.model.setAssistantMode(.manual, projectID: f.project)
            XCTAssertTrue(f.model.heldJobs.isEmpty)
            XCTAssertEqual(f.model.skillOffers(inProject: f.project).count, 1, "held work becomes an offer in Manual")
            f.model.setAssistantMode(.off, projectID: f.project)
            XCTAssertTrue(f.model.skillOffers(inProject: f.project).isEmpty, "Off withdraws it")
            XCTAssertEqual(f.model.skillsData(inProject: f.project).candidates.first?.state, .collecting, "the lesson is kept")
        }
        XCTAssertEqual(f.runner.calls.count, 2)
    }

    func testTranscriptsKeptBackStopADraftWhenItRuns() async throws {
        let f = try await makeFixture()
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        await MainActor.run {
            f.model.dailyJobs = DailyJobCount(day: DailyJobCount.day(of: SkillTests.now), count: f.model.settings.assistant.dailyJobLimit)
        }
        let second = await MainActor.run { addSession(f) }
        await followUp(f, session: second)
        await MainActor.run {
            XCTAssertEqual(f.model.heldJobs.count, 1)
            var settings = ProjectAssistantSettings()
            settings.dontSendTranscripts = true
            f.model.setAssistantSettings(settings, projectID: f.project)
            f.model.dailyJobs = DailyJobCount(day: DailyJobCount.day(of: SkillTests.now), count: 0)
            f.model.releaseHeldJobs()
            XCTAssertTrue(f.model.heldJobs.isEmpty)
        }
        await f.model.waitForSkillDrafts()
        XCTAssertEqual(f.runner.calls.count, 2, "the setting is checked when the draft runs, not when it was queued")
    }

    func testADraftThatFailsItsChecksIsDroppedWithoutItsText() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        let leaky = #"{"action":"new","skill":null,"name":"deploy","description":"Deploy.","whenToUse":"","paths":[],"body":"Use ghp_abcdefghijklmnopqrstuvwxyz0123456789 to push.","why":"x"}"#
        answerFollowUpsAndDrafts(f, draft: leaky, remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            XCTAssertTrue(f.model.skillProposals(inProject: f.project).isEmpty, "never shown")
            let entry = f.model.log.entries.last { $0.title.contains("dropped a skill draft") }
            XCTAssertEqual(entry?.title, "Assistant: dropped a skill draft (deploy) that failed its checks")
            XCTAssertEqual(entry?.detail, "it looks like it holds a secret (a GitHub token)")
            XCTAssertFalse(f.model.log.entries.contains { ($0.detail ?? "").contains("ghp_") || $0.title.contains("ghp_") })
            let candidate = f.model.skillsData(inProject: f.project).candidates.first
            XCTAssertEqual(candidate?.state, .collecting)
            XCTAssertEqual(candidate?.heldUntilSessions, 2, "drafted again once one more session shows it")
        }
    }

    func testCommandsOffThePathAreWarningsOnTheCard() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { $0 != "frobnicate" } }
        let draft = #"{"action":"new","skill":null,"name":"frob","description":"Frob.","whenToUse":"","paths":[],"body":"```bash\nfrobnicate --all\n```","why":"x"}"#
        answerFollowUpsAndDrafts(f, draft: draft, remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            let proposal = f.model.skillProposals(inProject: f.project).first
            XCTAssertEqual(proposal?.warnings, ["It runs frobnicate, which isn't installed (it's not on your PATH)."], "shown, not dropped")
            XCTAssertTrue(f.model.log.entries.contains { $0.title == "Assistant: drafted a new skill: frob (1 to check before approving)" })
        }
    }

    func testNothingWorthASkillHoldsTheLessonBack() async throws {
        let f = try await makeFixture()
        answerFollowUpsAndDrafts(f, draft: #"{"action":"none","skill":null,"name":"","description":"","whenToUse":"","paths":[],"body":"","why":""}"#,
                                 remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            XCTAssertTrue(f.model.skillProposals(inProject: f.project).isEmpty)
            XCTAssertEqual(f.model.skillsData(inProject: f.project).candidates.first?.heldUntilSessions, 3)
        }
    }

    func testAPatchIsDraftedAgainstTheApprovedSkill() async throws {
        let f = try await makeFixture()
        let approved = SkillText.compose(name: "linux-tests", description: "Old.", whenToUse: "", paths: [], body: "Old body.",
                                         metadata: [("claudio-id", "6f9619ff-8b86-d011-b42d-00c04fc964ff"), ("claudio-version", "2")])
        await MainActor.run {
            f.model.commandExistsOverride = { _ in true }
            f.assistant.skills[f.project] = [SkillFiles.skill(fromSkillFile: approved, folderName: "linux-tests")]
            f.model.refreshApprovedSkills(projectID: f.project)
        }
        let patch = #"{"action":"patch","skill":"linux-tests","name":"linux-tests","description":"New.","whenToUse":"","paths":[],"body":"New body.","why":"x"}"#
        answerFollowUpsAndDrafts(f, draft: patch, remember: true)
        await followUp(f, session: f.session, remember: true)
        try await MainActor.run {
            let proposal = try XCTUnwrap(f.model.skillProposals(inProject: f.project).first)
            XCTAssertTrue(proposal.isChange)
            XCTAssertEqual(proposal.previousText, approved)
            let skill = SkillFiles.skill(fromSkillFile: proposal.text, folderName: "x")
            XCTAssertEqual(skill.version, 3)
            XCTAssertEqual(skill.claudioID, UUID(uuidString: "6f9619ff-8b86-d011-b42d-00c04fc964ff"), "the same skill")
        }
        let call = try XCTUnwrap(f.runner.calls.last)
        XCTAssertTrue(call.contains { $0.contains("Old body.") }, "the draft sees the approved skills")
    }

    func testAFailedBackgroundDraftCanBeTriedAgain() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        let followUp = #"{"notes":[],"planChanges":[],"lessons":[{"summary":"Run the Linux script.","evidence":["f1"],"remember":false}]}"#
        f.runner.answer = { args in
            args.contains { $0.contains("\"lessons\"") } ? SkillRunner.reply(followUp)
                : CommandResult(exitCode: 1, output: (try? Fixtures.string("assistant-signed-out.json")) ?? "", errorOutput: "")
        }
        await self.followUp(f, session: f.session)
        let second = await MainActor.run { addSession(f) }
        await self.followUp(f, session: second)
        let row = try await MainActor.run { () -> AssistantLogRow in
            XCTAssertNil(f.model.errorMessage, "a background failure isn't an alert")
            f.model.refreshAssistantLog(projectID: f.project)
            let row = try XCTUnwrap(f.model.assistantLog(forProject: f.project).first { $0.job == SkillDraftJob.job })
            XCTAssertEqual(row.subject, "Run the Linux script")
            return row
        }
        let candidate = try await MainActor.run { try XCTUnwrap(f.model.skillsData(inProject: f.project).candidates.first) }
        XCTAssertEqual(row.retry, .skillDraft(candidateID: candidate.id))
        answerFollowUpsAndDrafts(f)
        await MainActor.run { XCTAssertTrue(f.model.retry(.skillDraft(candidateID: candidate.id), projectID: f.project)) }
        await f.model.waitForSkillDrafts()
        await MainActor.run { XCTAssertEqual(f.model.skillProposals(inProject: f.project).count, 1) }
    }

    // MARK: - Approval

    static let skillID = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

    static func skillText(_ body: String, version: Int = 1, description: String = "Run the tests on Linux.") -> String {
        SkillText.compose(name: "linux-tests", description: description, whenToUse: "", paths: [], body: body,
                          metadata: [("claudio-id", skillID), ("claudio-version", String(version))])
    }

    /// A proposal waiting in Needs You, from a candidate.
    @MainActor func propose(_ f: Fixture, text: String, previous: String? = nil) -> SkillProposal {
        var candidate = LessonCandidate(signature: "s", summary: "Use the script.", evidence: [], remember: false, at: SkillTests.now)
        candidate.state = .proposed
        let proposal = SkillProposal(candidateID: candidate.id, name: "linux-tests", text: text, previousText: previous, why: "Stops failures.",
                                     createdAt: SkillTests.now, model: "Sonnet")
        f.model.updateSkillsData(f.project) { data in
            data.candidates.append(candidate)
            data.proposals.append(proposal)
        }
        f.model.commandExistsOverride = { _ in true }
        return proposal
    }

    func testApprovingANewSkillWritesItAndItsHistory() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it in Docker."))
            f.model.openSkillProposal(proposal.id, projectID: f.project)
            XCTAssertNotNil(f.model.shownAssistantPanel)
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            let skill = try XCTUnwrap(f.model.approvedSkills[f.project]?.first)
            XCTAssertEqual(skill.name, "linux-tests")
            XCTAssertEqual(skill.version, 1)
            XCTAssertEqual(f.assistant.skillHistory(name: "linux-tests", projectID: f.project).map(\.version), [1])
            let data = f.model.skillsData(inProject: f.project)
            XCTAssertTrue(data.proposals.isEmpty)
            XCTAssertTrue(data.candidates.isEmpty, "its lesson is done with")
            XCTAssertEqual(data.records.first?.version, 1)
            XCTAssertEqual(data.records.first?.contentHash, SkillText.hash(skill.text), "for 5b's check for outside edits")
            XCTAssertEqual(data.usage["linux-tests"]?.lastUsed, SkillTests.now, "approving counts as a use")
            XCTAssertEqual(data.usage["linux-tests"]?.sessions, [], "but no session used it")
            XCTAssertNil(f.model.shownAssistantPanel, "the proposal has gone")
            XCTAssertEqual(f.model.toast?.text, "Approved linux-tests. Sessions pick it up within a few seconds.")
            XCTAssertEqual(f.model.skillRows(inProject: f.project).map(\.name), ["linux-tests"])
            XCTAssertEqual(f.model.skillRows(inProject: f.project).first?.changedAt, SkillTests.now)
        }
    }

    func testApprovingAChangeBumpsTheVersion() async throws {
        let f = try await makeFixture()
        let old = SkillTests.skillText("Old.", version: 2)
        await MainActor.run {
            f.assistant.skills[f.project] = [SkillFiles.skill(fromSkillFile: old, folderName: "linux-tests")]
            f.model.refreshApprovedSkills(projectID: f.project)
            let proposal = propose(f, text: SkillTests.skillText("New.", version: 1), previous: old)
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            let skill = f.model.approvedSkills[f.project]?.first
            XCTAssertEqual(skill?.version, 3, "worked out at approval, whatever the draft says")
            XCTAssertEqual(f.assistant.skillHistory(name: "linux-tests", projectID: f.project).map(\.version), [3])
            XCTAssertEqual(skill?.claudioID, UUID(uuidString: SkillTests.skillID))
            XCTAssertEqual(SkillText.body(of: skill?.text ?? ""), "New.")
        }
    }

    func testAChangeToASkillEditedSinceIsRefused() async throws {
        let f = try await makeFixture()
        let old = SkillTests.skillText("Old.", version: 2)
        await MainActor.run {
            f.assistant.skills[f.project] = [SkillFiles.skill(fromSkillFile: SkillTests.skillText("Edited by hand.", version: 2),
                                                              folderName: "linux-tests")]
            let proposal = propose(f, text: SkillTests.skillText("New.", version: 3), previous: old)
            XCTAssertFalse(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            XCTAssertEqual(f.model.toast?.text, "linux-tests changed after this was drafted, so it wasn't approved. Not Now drops this draft.")
            XCTAssertEqual(SkillText.body(of: f.model.approvedSkills[f.project]?.first?.text ?? ""), "Edited by hand.", "left as it was")
            XCTAssertNotNil(f.model.skillProposal(proposal.id, inProject: f.project))
        }
    }

    func testANewSkillWhoseNameWasTakenIsRefused() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Mine."))
            f.assistant.skills[f.project] = [ApprovedSkill(name: "linux-tests", text: "theirs")]
            XCTAssertFalse(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            XCTAssertEqual(f.model.approvedSkills[f.project]?.first?.text, "theirs")
        }
    }

    func testEditingAProposalIsChecked() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            let renamed = SkillText.compose(name: "other", description: "d", whenToUse: "", paths: [], body: "b", metadata: [])
            XCTAssertEqual(f.model.editSkillProposal(proposal.id, text: renamed, projectID: f.project).first,
                           "the name can't change while editing (it's linux-tests)")
            let leaky = SkillTests.skillText("Token: ghp_abcdefghijklmnopqrstuvwxyz0123456789")
            XCTAssertTrue(f.model.editSkillProposal(proposal.id, text: leaky, projectID: f.project)
                .contains("it looks like it holds a secret (a GitHub token)"))
            XCTAssertEqual(f.model.skillProposal(proposal.id, inProject: f.project)?.text, proposal.text, "not saved")
            let better = SkillTests.skillText("Run it in Docker, then push.")
            XCTAssertEqual(f.model.editSkillProposal(proposal.id, text: better, projectID: f.project), [])
            XCTAssertEqual(f.model.skillProposal(proposal.id, inProject: f.project)?.text, better)
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            XCTAssertEqual(SkillText.body(of: f.model.approvedSkills[f.project]?.first?.text ?? ""), "Run it in Docker, then push.")
        }
    }

    func testNotNowOnAProposalHoldsItsLessonBack() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1)
            f.model.dismissSkillProposal(proposal.id, projectID: f.project)
            XCTAssertTrue(f.model.skillProposals(inProject: f.project).isEmpty)
            let candidate = f.model.skillsData(inProject: f.project).candidates.first
            XCTAssertEqual(candidate?.state, .collecting)
            XCTAssertEqual(candidate?.heldUntilSessions, 2)
            XCTAssertTrue(f.model.approvedSkills[f.project]?.isEmpty ?? true, "nothing loads a draft you didn't approve")
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 0)
        }
    }

    func testASkillThatCantBeWrittenStaysProposed() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            assistant.skillWriteError = CocoaError(.fileWriteNoPermission)
            XCTAssertFalse(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            XCTAssertNotNil(f.model.errorMessage)
            XCTAssertNotNil(f.model.skillProposal(proposal.id, inProject: f.project))
            XCTAssertTrue(f.model.skillsData(inProject: f.project).records.isEmpty)
        }
    }

    func testTheFileStoreWritesSkillsAndHistory() throws {
        let store = AssistantFileStore(root: try makeTemporaryDirectory())
        let project = UUID()
        _ = try store.skillsRoot(projectID: project)
        try store.writeSkillHistory(name: "linux-tests", version: 1, text: SkillTests.skillText("One."), projectID: project)
        try store.writeSkillHistory(name: "linux-tests", version: 2, text: SkillTests.skillText("Two.", version: 2), projectID: project)
        try store.writeApprovedSkill(name: "linux-tests", text: SkillTests.skillText("Two.", version: 2), projectID: project)
        XCTAssertEqual(store.approvedSkills(projectID: project).map(\.version), [2])
        XCTAssertEqual(store.skillHistory(name: "linux-tests", projectID: project).map(\.version), [2, 1])
        XCTAssertNotNil(store.skillHistory(name: "linux-tests", projectID: project).first?.approvedAt)
        var data = SkillsData()
        _ = data.recordUse(of: "linux-tests", by: UUID(), at: SkillTests.now)
        try store.saveSkillsData(data, projectID: project)
        XCTAssertEqual(try store.loadSkillsData(projectID: project), data)
        let file = store.directory(projectID: project).appendingPathComponent("skills.json")
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.loadSkillsData(projectID: project))
    }

    // MARK: - Remember this asks once

    func testAFailedRememberDraftIsntAskedAgainOnYourBehalf() async throws {
        let f = try await makeFixture()
        let followUp = #"{"notes":[],"planChanges":[],"lessons":[{"summary":"Use the script.","evidence":["f1","c1"],"remember":true}]}"#
        f.runner.answer = { args in
            args.contains { $0.contains("\"lessons\"") } ? SkillRunner.reply(followUp)
                : CommandResult(exitCode: 1, output: (try? Fixtures.string("assistant-signed-out.json")) ?? "", errorOutput: "")
        }
        await self.followUp(f, session: f.session, remember: true)
        XCTAssertEqual(f.runner.calls.count, 2, "drafted straight away, and it failed")
        await MainActor.run {
            XCTAssertEqual(f.model.errorMessage, AssistantFailure.signedOut.message, "you asked, so you're told")
            f.model.errorMessage = nil
            XCTAssertEqual(f.model.skillsData(inProject: f.project).candidates.first?.remember, false)
            f.model.setAssistantMode(.manual, projectID: f.project)
            f.model.setAssistantMode(.automatic, projectID: f.project)
        }
        await f.model.waitForSkillDrafts()
        XCTAssertEqual(f.runner.calls.count, 2, "a mode change doesn't ask again")
        await MainActor.run { XCTAssertNil(f.model.errorMessage) }
    }

    func testTurningTheAssistantBackOnOffersDraftsAgain() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.setAssistantMode(.manual, projectID: f.project) }
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        let second = await MainActor.run { addSession(f) }
        await followUp(f, session: second)
        await MainActor.run {
            XCTAssertEqual(f.model.skillOffers(inProject: f.project).count, 1)
            var settings = f.model.settings
            settings.assistant.isEnabled = false
            f.model.updateSettings(settings)
            XCTAssertTrue(f.model.skillOffers(inProject: f.project).isEmpty, "withdrawn")
            settings.assistant.isEnabled = true
            f.model.updateSettings(settings)
            XCTAssertEqual(f.model.skillOffers(inProject: f.project).count, 1, "offered again")
        }
    }

    // MARK: - Review round 1 (PR #38)

    func testADraftNameWithALineBreakMakesNoProposal() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        let escaping = #"{"action":"new","skill":null,"name":"ok-name\n../../../../.claude/skills/x","description":"d","whenToUse":"","paths":[],"body":"b","why":"w"}"#
        answerFollowUpsAndDrafts(f, draft: escaping, remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            XCTAssertTrue(f.model.skillProposals(inProject: f.project).isEmpty)
            XCTAssertTrue(f.model.log.entries.contains { $0.title == "Assistant: a skill draft came back in a form Claudio couldn't use" })
        }
    }

    func testApproveRefusesANameThatDoesntMatchItsText() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            var proposal = propose(f, text: SkillTests.skillText("Run it."))
            f.model.updateSkillsData(f.project) { data in data.proposals[0].name = "../../evil" }
            proposal = f.model.skillProposals(inProject: f.project)[0]
            XCTAssertFalse(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            f.model.updateSkillsData(f.project) { data in data.proposals[0].name = "other-name" }
            XCTAssertFalse(f.model.approveSkillProposal(proposal.id, projectID: f.project), "a slug, but not the text's name")
            XCTAssertEqual(f.model.toast?.text, "This draft's name doesn't match its text, so it wasn't approved. Not Now drops it.")
            XCTAssertTrue(f.assistant.skills[f.project]?.isEmpty ?? true, "nothing written")
        }
    }

    func testTheFileStoreRefusesNamesThatArentSlugs() throws {
        let root = try makeTemporaryDirectory()
        let store = AssistantFileStore(root: root.appendingPathComponent("assistant"))
        let project = UUID()
        XCTAssertThrowsError(try store.writeApprovedSkill(name: "../evil", text: "x", projectID: project))
        XCTAssertThrowsError(try store.writeSkillHistory(name: "a/../../b", version: 1, text: "x", projectID: project))
        XCTAssertThrowsError(try store.writeApprovedSkill(name: "ok\nname", text: "x", projectID: project))
        XCTAssertEqual(store.skillHistory(name: "../x", projectID: project), [])
        let written = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        XCTAssertFalse(written.contains { $0.contains("SKILL.md") || $0.hasSuffix(".md") }, "nothing written anywhere")
    }

    func testASecretInTheReasonOrAPathIsntLogged() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let draft = #"{"action":"new","skill":null,"name":"deploy","description":"Deploy.","whenToUse":"","paths":[],"body":"See `secrets/\#(token).txt`.","why":"Use \#(token)"}"#
        answerFollowUpsAndDrafts(f, draft: draft, remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            XCTAssertTrue(f.model.skillProposals(inProject: f.project).isEmpty)
            let entry = f.model.log.entries.last { $0.title.contains("dropped a skill draft") }
            XCTAssertNotNil(entry)
            XCTAssertTrue(entry?.detail?.contains("its reason looks like it holds a secret (a GitHub token)") ?? false)
            XCTAssertFalse(f.model.log.entries.contains { !SecretPatterns.matches(in: $0.title + ($0.detail ?? "")).isEmpty },
                           "no log line holds anything like a secret")
        }
    }

    func testALessonWhoseDraftWasReplacedGoesBackToGathering() async throws {
        let f = try await makeFixture()
        let approved = SkillTests.skillText("Old.", version: 1)
        await MainActor.run {
            f.model.commandExistsOverride = { _ in true }
            f.assistant.skills[f.project] = [SkillFiles.skill(fromSkillFile: approved, folderName: "linux-tests")]
            f.model.refreshApprovedSkills(projectID: f.project)
            _ = propose(f, text: SkillTests.skillText("A's change."), previous: approved)
        }
        let first = await MainActor.run { f.model.skillsData(inProject: f.project).candidates[0].id }
        let patch = #"{"action":"patch","skill":"linux-tests","name":"linux-tests","description":"New.","whenToUse":"","paths":[],"body":"B's change.","why":"x"}"#
        answerFollowUpsAndDrafts(f, draft: patch, remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            XCTAssertEqual(f.model.skillProposals(inProject: f.project).count, 1, "B's draft replaced A's")
            let a = f.model.skillCandidate(first, inProject: f.project)
            XCTAssertEqual(a?.state, .collecting, "not stuck waiting on a draft that's gone")
        }
    }

    func testAStuckLessonIsFreedAtLaunch() async throws {
        let assistant = MemoryAssistantStore()
        var data = SkillsData()
        data.add([LessonFinding(summary: "s", evidence: [SessionDigest.Evidence(ref: "f1", kind: .failure, command: "make", text: "boom")],
                                remember: false, signature: "bash make | boom")],
                 sessionID: UUID(), sessionName: "One", at: SkillTests.now)
        data.candidates[0].state = .proposed
        let project = UUID()
        assistant.skillsData[project] = data
        let f = try await makeFixture(assistant: assistant)
        _ = f
        // The fixture's project has its own id, so check the reconcile directly too.
        var stuck = data
        stuck.reconcileProposals()
        XCTAssertEqual(stuck.candidates[0].state, .collecting)
        XCTAssertEqual(stuck.candidates[0].heldUntilSessions, 2)
    }

    func testPathCheckOnlyRunsAFixedScript() async throws {
        let f = try await makeFixture()
        f.runner.scriptOutput = CommandResult(exitCode: 0, output: "Welcome to zsh\n/usr/bin:/bin", errorOutput: "")
        let draft = #"{"action":"new","skill":null,"name":"wipe","description":"Wipe.","whenToUse":"","paths":[],"body":"```bash\nrm -rf x; $(touch /tmp/pwn)\nnotarealcommand --go\n```","why":"x"}"#
        answerFollowUpsAndDrafts(f, draft: draft, remember: true)
        await followUp(f, session: f.session, remember: true)
        XCTAssertEqual(f.runner.scripts.count, 1, "read once")
        XCTAssertTrue(f.runner.scripts[0].hasSuffix(#"printf '\n%s' "$PATH""#), "a fixed script: nothing from the draft")
        XCTAssertFalse(f.runner.scripts[0].contains("touch"))
        await MainActor.run {
            XCTAssertEqual(f.model.loginShellPATH, ["/usr/bin", "/bin"], "the last line, after a profile's own")
            XCTAssertEqual(f.model.skillProposals(inProject: f.project).first?.warnings,
                           ["It runs notarealcommand, which isn't installed (it's not on your PATH)."])
        }
    }

    func testAFailedPathReadIsTriedAgainLater() async throws {
        var clock = SkillTests.now
        let f = try await makeFixture(clock: { clock })
        f.runner.scriptOutput = CommandResult(exitCode: 1, output: "", errorOutput: "zsh: broken profile")
        var check = await f.model.commandCheck()
        XCTAssertNil(check, "skipped, not failed")
        check = await f.model.commandCheck()
        XCTAssertEqual(f.runner.scripts.count, 1, "not again straight away")
        clock = clock.addingTimeInterval(AppModel.loginShellPATHRetry)
        f.runner.scriptOutput = CommandResult(exitCode: 0, output: "/usr/bin", errorOutput: "")
        check = await f.model.commandCheck()
        XCTAssertEqual(f.runner.scripts.count, 2, "tried again after a while")
        XCTAssertNotNil(check)
    }

    func testUnresolvedLessonsAreCountedInTheLog() async throws {
        let f = try await makeFixture()
        let followUp = #"{"notes":[],"planChanges":[],"lessons":[{"summary":"Made up.","evidence":["f9"],"remember":false}]}"#
        f.runner.answer = { _ in SkillRunner.reply(followUp) }
        await self.followUp(f, session: f.session)
        await MainActor.run {
            XCTAssertTrue(f.model.skillsData(inProject: f.project).candidates.isEmpty)
            XCTAssertTrue(f.model.log.entries.contains { $0.title == "Assistant: dropped 1 lesson from a follow-up" })
        }
    }

    // MARK: - With main's features (nested folders, usage)

    func testChipUsageCountsSessionsNestedUnderTheFolder() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            f.assistant.skills[f.project] = [ApprovedSkill(name: "used-below")]
            f.model.refreshApprovedSkills(projectID: f.project)
            let parent = try XCTUnwrap(f.model.createFolder(in: f.project))
            let child = try XCTUnwrap(f.model.createFolder(in: f.project, containing: f.session, parentID: parent))
            f.model.updateSkillsData(f.project) { _ = $0.recordUse(of: "used-below", by: f.session, at: SkillTests.now) }
            let item = PlanItem(title: "Next", status: .planned, createdAt: SkillTests.now)
            XCTAssertEqual(f.model.skillUsage(inProject: f.project, folderID: child), ["used-below": 1])
            XCTAssertEqual(f.model.skillUsage(inProject: f.project, folderID: parent), ["used-below": 1],
                           "a session in a subfolder counts for the folder above it")
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project, folderID: parent), ["used-below"])
            XCTAssertEqual(f.model.skillUsage(inProject: f.project, folderID: nil), [:], "it isn't Unfiled")
        }
    }

    func testASkillDraftsCostIsCountedForTheProject() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        answerFollowUpsAndDrafts(f, remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            let drafts = f.model.usageEntries.filter {
                if case .assistant(let job, _) = $0.source { return job == SkillDraftJob.job }
                return false
            }
            XCTAssertEqual(drafts.count, 1, "in Usage's assistant spend, by its Activity Log name")
            XCTAssertEqual(drafts.first?.cost ?? 0, 0.03, accuracy: 0.0001)
            XCTAssertEqual(drafts.first?.projectID, f.project)
            XCTAssertNil(drafts.first?.sessionID, "a lesson isn't a session: it's the project's")
        }
    }

    // MARK: - Tim's first test (2026-10-12): an example path dropped the draft

    func testAnExamplePathDoesntDropTheDraft() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        let draft = #"{"action":"new","skill":null,"name":"check-folder-before-ls","description":"Check a folder exists before listing it.","whenToUse":"","paths":[],"body":"Before `ls ./some-folder`, run `test -d ./some-folder`. For example, `./no-such-folder` fails.\nAlso see `scripts/missing.sh`.","why":"Stops failed ls calls"}"#
        answerFollowUpsAndDrafts(f, draft: draft, remember: true)
        await followUp(f, session: f.session, remember: true)
        try await MainActor.run {
            let proposal = try XCTUnwrap(f.model.skillProposals(inProject: f.project).first, "it reaches Needs You")
            XCTAssertEqual(proposal.warnings, ["It mentions scripts/missing.sh, which isn't in the repository."],
                           "a bare `./no-such-folder` isn't a path; a real-looking one that's missing is a warning")
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 2, "the follow-up and the new skill")
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project), "a warning doesn't stop approval")
        }
    }

    func testEditingRecomputesTheWarnings() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run `scripts/missing.sh`."))
            XCTAssertEqual(f.model.editSkillProposal(proposal.id, text: SkillTests.skillText("Run `scripts/gone.sh`."), projectID: f.project), [])
            XCTAssertEqual(f.model.skillProposal(proposal.id, inProject: f.project)?.warnings,
                           ["It mentions scripts/gone.sh, which isn't in the repository."])
            XCTAssertEqual(f.model.editSkillProposal(proposal.id, text: SkillTests.skillText("Run it in Docker."), projectID: f.project), [])
            XCTAssertEqual(f.model.skillProposal(proposal.id, inProject: f.project)?.warnings, [])
        }
    }

    // MARK: - Tim's test (2026-10-13): "Nothing new to keep" for a follow-up that kept a lesson

    func testAFollowUpThatKeptALessonSaysSo() async throws {
        let f = try await makeFixture()
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        try await MainActor.run {
            let card = try XCTUnwrap(f.model.followUpCard(forSession: f.session))
            XCTAssertEqual(card.lessons, ["Run the Linux script, not swift test."])
            XCTAssertFalse(card.hasNothingToKeep, "it kept a lesson")
            XCTAssertTrue(f.model.log.entries.contains { $0.title == "Assistant: followed up Shell Height: 0 notes, 0 plan changes, 1 lesson" })
            let saved = try JSONFileStore.decoder.decode(FollowUp.self, from: JSONFileStore.encoder.encode(card))
            XCTAssertEqual(saved.lessons, card.lessons, "kept with the card")
        }
    }

    // MARK: - Step 5b: tags

    @MainActor func addTag(_ f: Fixture, _ name: String) -> Tag {
        f.model.addTag(named: name)!
    }

    func testChipsUseTheChosenTags() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let frontend = addTag(f, "Frontend")
            f.assistant.skills[f.project] = [ApprovedSkill(name: "frontend-style", tags: ["Frontend"]), ApprovedSkill(name: "used-by-frontend")]
            f.model.refreshApprovedSkills(projectID: f.project)
            let item = PlanItem(title: "Next", status: .planned, createdAt: SkillTests.now)
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project), [])
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project, tagIDs: [frontend.id]), ["frontend-style"])
            // A Frontend session anywhere used the other skill.
            f.model.applyTestSessionChange(f.session) { $0.tags = [frontend.id] }
            let folder = f.model.createFolder(in: f.project)
            f.model.updateSkillsData(f.project) { _ = $0.recordUse(of: "used-by-frontend", by: f.session, at: SkillTests.now) }
            XCTAssertEqual(f.model.skillUsage(inProject: f.project, folderID: folder, tagIDs: [frontend.id]), ["used-by-frontend": 1],
                           "counted by its tag, though it's in another folder")
            XCTAssertEqual(f.model.suggestedSkills(forItem: item, inProject: f.project, folderID: folder, tagIDs: [frontend.id]),
                           ["frontend-style", "used-by-frontend"])
        }
    }

    func testADraftGetsTheSessionsTags() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let frontend = addTag(f, "Frontend")
            f.model.applyTestSessionChange(f.session) { $0.tags = [frontend.id] }
            f.model.commandExistsOverride = { _ in true }
        }
        let draft = #"{"action":"new","skill":null,"name":"linux-tests","description":"Run the Linux tests.","whenToUse":"","paths":[],"tags":["Frontend","Nope"],"body":"Run them in Docker.","why":"x"}"#
        answerFollowUpsAndDrafts(f, draft: draft, remember: true)
        await followUp(f, session: f.session, remember: true)
        let call = try XCTUnwrap(f.runner.calls.last)
        XCTAssertTrue(call.contains { $0.contains(#""sessionTags":["Frontend"]"#) }, "the evidence sessions' tags")
        try await MainActor.run {
            let proposal = try XCTUnwrap(f.model.skillProposals(inProject: f.project).first)
            XCTAssertEqual(SkillFiles.skill(fromSkillFile: proposal.text, folderName: "x").tags, ["Frontend"])
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            XCTAssertEqual(f.model.skillRows(inProject: f.project).first?.tags, ["Frontend"])
            XCTAssertEqual(f.model.skillRows(inProject: f.project).first?.unknownTags, [])
            let frontend = try XCTUnwrap(f.model.settings.tags.first { $0.name == "Frontend" })
            f.model.renameTag(frontend.id, to: "Web")
            XCTAssertEqual(f.model.skillRows(inProject: f.project).first?.unknownTags, ["Frontend"], "renamed in the catalog")
        }
    }

    // MARK: - Step 5b: repository skills and Save to Repository

    /// A fixture whose project is a real (temporary) folder.
    func makeRepositoryFixture(assistant: MemoryAssistantStore = MemoryAssistantStore()) async throws -> (Fixture, URL) {
        let repo = try makeTemporaryDirectory()
        return (try await makeFixture(assistant: assistant, projectPath: repo.path), repo)
    }

    func writeRepositorySkill(_ repo: URL, _ name: String, _ text: String) throws {
        let folder = repo.appendingPathComponent(".claude/skills/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func testTheRepositorysOwnSkillsAreListed() async throws {
        let (f, repo) = try await makeRepositoryFixture()
        try writeRepositorySkill(repo, "release-notes", "---\nname: release-notes\ndescription: Write release notes.\n---\nBody\n")
        try writeHooks([["hook_event_name": "UserPromptSubmit", "session_id": SkillTests.conversation, "prompt": "/release-notes"]], f)
        await MainActor.run {
            f.model.refreshApprovedSkills(projectID: f.project)
            let rows = f.model.skillRows(inProject: f.project)
            XCTAssertEqual(rows.map(\.name), ["release-notes"])
            XCTAssertEqual(rows.first?.location, .repository)
            XCTAssertEqual(rows.first?.savedByClaudio, false, "yours, so Claudio doesn't review edits to it")
            f.model.pollHookEvents()
            XCTAssertEqual(f.model.skillRows(inProject: f.project).first?.usedBy, 1, "its use is counted")
            XCTAssertEqual(f.model.skill(named: "release-notes", inProject: f.project)?.location, .repository)
        }
    }

    func testSaveToRepositoryMovesTheSkill() async throws {
        let (f, repo) = try await makeRepositoryFixture()
        try await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it in Docker."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            XCTAssertTrue(f.model.saveSkillToRepository("linux-tests", projectID: f.project))
            let file = repo.appendingPathComponent(".claude/skills/linux-tests/SKILL.md")
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(SkillText.body(of: text), "Run it in Docker.")
            XCTAssertTrue(f.assistant.skills[f.project]?.isEmpty ?? true, "Claudio's copy is gone, so it doesn't load twice")
            let record = try XCTUnwrap(f.model.skillsData(inProject: f.project).records.first)
            XCTAssertEqual(record.location, .repository)
            XCTAssertEqual(record.contentHash, SkillText.hash(text), "the copy it wrote, for reviewing edits later")
            let row = try XCTUnwrap(f.model.skillRows(inProject: f.project).first)
            XCTAssertEqual(row.location, .repository)
            XCTAssertTrue(row.savedByClaudio)
            XCTAssertEqual(f.model.toast?.text, "Saved linux-tests to the repository. Commit .claude/skills/linux-tests/SKILL.md to share it.")
        }
    }

    func testSaveToRepositoryWontOverwriteTheRepositorysSkill() async throws {
        let (f, repo) = try await makeRepositoryFixture()
        try writeRepositorySkill(repo, "linux-tests", "---\nname: linux-tests\ndescription: Theirs.\n---\nTheirs\n")
        await MainActor.run {
            f.assistant.skills[f.project] = [SkillFiles.skill(fromSkillFile: SkillTests.skillText("Mine."), folderName: "linux-tests")]
            f.model.refreshApprovedSkills(projectID: f.project)
            XCTAssertFalse(f.model.saveSkillToRepository("linux-tests", projectID: f.project))
            XCTAssertEqual(f.model.toast?.text, "The repository already has a skill called linux-tests, so this one wasn't saved there")
            XCTAssertEqual(f.assistant.skills[f.project]?.count, 1, "Claudio's copy stays")
        }
        let theirs = try String(contentsOf: repo.appendingPathComponent(".claude/skills/linux-tests/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(theirs.contains("Theirs"), "untouched")
    }

    func testAFailedRemovalTakesTheRepositoryCopyBack() async throws {
        let assistant = MemoryAssistantStore()
        let (f, repo) = try await makeRepositoryFixture(assistant: assistant)
        await MainActor.run {
            assistant.skills[f.project] = [SkillFiles.skill(fromSkillFile: SkillTests.skillText("Mine."), folderName: "linux-tests")]
            f.model.refreshApprovedSkills(projectID: f.project)
            assistant.skillWriteError = CocoaError(.fileWriteNoPermission)
            XCTAssertFalse(f.model.saveSkillToRepository("linux-tests", projectID: f.project))
            XCTAssertNotNil(f.model.errorMessage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".claude/skills/linux-tests").path),
                       "never loaded twice")
    }

    // MARK: - Step 5b: skill sets

    @MainActor func approve(_ f: Fixture, _ names: [String]) {
        f.assistant.skills[f.project] = names.map { ApprovedSkill(name: $0, folder: $0) }
        f.model.refreshApprovedSkills(projectID: f.project)
    }

    @MainActor func planItem(_ f: Fixture) throws -> PlanItem {
        let note = try XCTUnwrap(f.model.addNote("Shell height", author: .user, projectID: f.project, sessionID: nil))
        return try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project, title: "Shell height"))
    }

    func testAPlanItemSessionWithSkillsGetsItsOwnSet() async throws {
        let f = try await makeFixture()
        let id = try await MainActor.run { () -> UUID in
            approve(f, ["a-skill", "b-skill"])
            let item = try planItem(f)
            let id = try XCTUnwrap(f.model.startSession(fromItem: item.id, projectID: f.project, name: "S", folderID: nil, tagIDs: [],
                                                       skills: ["a-skill", "not-approved"], useWorktree: false))
            XCTAssertEqual(f.model.workspace.session(id)?.skillSet, ["a-skill"], "only approved skills")
            return id
        }
        await f.model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(f.assistant.sessionSkills[id], ["a-skill"], "its links are made when it launches")
        }
    }

    func testNoChipsMeansTheSharedSkills() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            approve(f, ["a-skill"])
            let item = try planItem(f)
            let id = try XCTUnwrap(f.model.startSession(fromItem: item.id, projectID: f.project, name: "S", folderID: nil, tagIDs: [],
                                                       skills: [], useWorktree: false))
            XCTAssertNil(f.model.workspace.session(id)?.skillSet, "Tim's call: an empty set means the shared skills")
            XCTAssertNil(f.assistant.sessionSkills[id])
        }
    }

    func testASetChangesLiveAndOnlyHoldsApprovedSkills() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            approve(f, ["a-skill", "b-skill"])
            f.model.setSessionSkillSet(f.session, ["a-skill"])
            f.model.setSkillSet(["a-skill", "b-skill", "made-up"], forSession: f.session)
            XCTAssertEqual(f.model.workspace.session(f.session)?.skillSet, ["a-skill", "b-skill"])
            XCTAssertEqual(f.assistant.sessionSkills[f.session], ["a-skill", "b-skill"], "links updated at once")
            f.model.setSkillSet([], forSession: f.session)
            XCTAssertEqual(f.assistant.sessionSkills[f.session], [], "its links go at once: none while it runs on its own root")
            XCTAssertNil(f.model.workspace.session(f.session)?.skillSet, "an empty set means the shared skills, from its next launch")
        }
    }

    func testASessionsLaunchUsesItsOwnRoot() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            approve(f, ["a-skill"])
            f.model.setSessionSkillSet(f.session, ["a-skill"])
            XCTAssertTrue(f.model.start(f.session))
            let launch = try XCTUnwrap(f.model.takePendingLaunch(f.session))
            let own = "/memory/\(f.project.uuidString.lowercased())/sessions/\(f.session.uuidString.lowercased())"
            XCTAssertTrue(launch.claudeArguments.containsSequence(["--add-dir", own]), "a direct --resume keeps its own set")
        }
    }

    func testDeletingEverywhereRemovesTheSetButRemovingFromClaudioKeepsIt() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            approve(f, ["a-skill"])
            f.model.setSessionSkillSet(f.session, ["a-skill"])
            f.model.setSkillSet(["a-skill"], forSession: f.session)
            _ = f.model.skillSetRoot(of: f.model.workspace.session(f.session)!)
            f.model.deleteSession(f.session, .claudioOnly)
            XCTAssertEqual(f.assistant.sessionSkills[f.session], ["a-skill"], "it can be restored, so its set stays")
            f.model.restoreSession(f.session)
            f.model.deleteSession(f.session, .everywhere)
            XCTAssertNil(f.assistant.sessionSkills[f.session], "gone from Claude Code: its root goes too")
        }
    }

    func testASkillSavedToTheRepositoryLeavesTheSets() async throws {
        let (f, _) = try await makeRepositoryFixture()
        await MainActor.run {
            f.assistant.skills[f.project] = [SkillFiles.skill(fromSkillFile: SkillTests.skillText("Run it."), folderName: "linux-tests"),
                                             ApprovedSkill(name: "other", folder: "other")]
            f.model.refreshApprovedSkills(projectID: f.project)
            f.model.setSessionSkillSet(f.session, ["linux-tests", "other"])
            XCTAssertTrue(f.model.saveSkillToRepository("linux-tests", projectID: f.project))
            XCTAssertEqual(f.model.workspace.session(f.session)?.skillSet, ["other"], "the repository's copy loads by itself")
            XCTAssertEqual(f.assistant.sessionSkills[f.session], ["other"])
        }
    }

    func testTheFileStoreLinksASessionsSkills() throws {
        let store = AssistantFileStore(root: try makeTemporaryDirectory())
        let project = UUID(), session = UUID()
        for name in ["a-skill", "b-skill"] {
            try store.writeApprovedSkill(name: name, text: "---\nname: \(name)\n---\n", projectID: project)
        }
        let root = try XCTUnwrap(try store.sessionSkillsRoot(projectID: project, sessionID: session, skills: ["a-skill", "gone", "../x"]))
        XCTAssertEqual(SkillFiles.approved(inRoot: root).map(\.name), ["a-skill"], "missing and bad names are left out")
        _ = try store.sessionSkillsRoot(projectID: project, sessionID: session, skills: ["b-skill"])
        XCTAssertEqual(SkillFiles.approved(inRoot: root).map(\.name), ["b-skill"], "a link not in the set is removed")
        let empty = try XCTUnwrap(try store.sessionSkillsRoot(projectID: project, sessionID: session, skills: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.appendingPathComponent(".claude/skills").path),
                      "the folder stays even when empty, so the session's root is always there")
        try store.removeSessionSkillsRoot(projectID: project, sessionID: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testASessionsSetSurvivesSaving() throws {
        var session = Session(projectID: UUID(), name: "s", workingDirectory: "/code/app")
        XCTAssertFalse(String(decoding: try JSONFileStore.encoder.encode(session), as: UTF8.self).contains("skillSet"),
                       "nil isn't written")
        session.skillSet = ["a-skill"]
        XCTAssertEqual(try JSONFileStore.decoder.decode(Session.self, from: JSONFileStore.encoder.encode(session)).skillSet, ["a-skill"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONFileStore.encoder.encode(session)) as? [String: Any])
        object["skillSet"] = 7
        let odd = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONFileStore.decoder.decode(Session.self, from: odd).skillSet, "unreadable: the shared skills")
    }

    // MARK: - Step 5b: drift (edited outside Claudio)

    struct DiskFixture {
        let model: AppModel
        let store: AssistantFileStore
        let project: UUID
        let session: UUID
        let repo: URL
        let hookLog: URL
    }

    /// A model on the real file store, with a real repository folder.
    func makeDiskFixture() async throws -> DiskFixture {
        let support = try makeTemporaryDirectory()
        let repo = try makeTemporaryDirectory()
        let store = AssistantFileStore(root: support.appendingPathComponent("assistant"))
        var state = PersistedState()
        let project = state.workspace.addProject(path: repo.path)
        let session = Session(projectID: project, claudeSessionID: SkillTests.conversation, hasConversation: true, name: "Update PR",
                              workingDirectory: repo.path, status: .completed)
        try state.workspace.addSession(session)
        let memory = MemoryStore()
        memory.state = state
        let hookLog = support.appendingPathComponent("h.log")
        let runner = SkillRunner()
        let model = await MainActor.run {
            AppModel(store: memory, discovery: SessionDiscovery(claudeHome: support), hookEventsURL: hookLog, runner: runner,
                     assistantStore: store, locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil },
                     shell: "/bin/sh", now: { SkillTests.now }, home: "/")
        }
        return DiskFixture(model: model, store: store, project: project, session: session.id, repo: repo, hookLog: hookLog)
    }

    /// Approves `linux-tests` through Needs You, as the app does.
    @MainActor func approveOnDisk(_ d: DiskFixture, body: String = "Run it in Docker.") -> URL {
        let proposal = SkillProposal(candidateID: nil, name: "linux-tests", text: SkillTests.skillText(body), previousText: nil,
                                     why: "w", createdAt: SkillTests.now, model: "Sonnet")
        d.model.updateSkillsData(d.project) { $0.proposals.append(proposal) }
        d.model.commandExistsOverride = { _ in true }
        XCTAssertTrue(d.model.approveSkillProposal(proposal.id, projectID: d.project))
        return d.store.approvedSkillFile(name: "linux-tests", projectID: d.project)!
    }

    func testClaudiosOwnWritesArentOutsideEdits() async throws {
        let d = try await makeDiskFixture()
        await MainActor.run {
            _ = approveOnDisk(d)
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty, "approving isn't an outside edit")
        }
    }

    func testAnEditOutsideClaudioIsFoundAndKept() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "Run it in Docker.", with: "Run it anywhere.")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertFalse(edit.deleted)
            XCTAssertEqual(d.model.outsideEditLine(edit), "linux-tests/SKILL.md in Claudio's skills was changed just now")
            XCTAssertEqual(SkillText.body(of: d.model.approvedText(of: "linux-tests", at: .claudio, inProject: d.project) ?? ""), "Run it in Docker.")
            XCTAssertEqual(d.model.needsYouCount(inProject: d.project), 1)
            d.model.checkSkillDrift()
            XCTAssertEqual(d.model.outsideEdits(inProject: d.project).count, 1, "not asked twice")
            XCTAssertTrue(d.model.keepOutsideEdit(edit.id, projectID: d.project))
            let record = try XCTUnwrap(d.model.skillsData(inProject: d.project).records.first)
            XCTAssertEqual(record.version, 2, "the change is its next version")
            let kept = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(kept.contains("claudio-version: 2"), "the file says so too")
            XCTAssertTrue(kept.contains("Run it anywhere."), "the change itself is kept")
            XCTAssertEqual(record.contentHash, SkillText.hash(kept))
            XCTAssertNotEqual(kept, edited)
            XCTAssertEqual(d.store.skillHistory(name: "linux-tests", projectID: d.project).map(\.version), [2, 1])
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty)
        }
    }

    func testRevertPutsTheApprovedTextBack() async throws {
        let d = try await makeDiskFixture()
        let (file, approved) = await MainActor.run { () -> (URL, String) in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return (file, try! String(contentsOf: file, encoding: .utf8))
        }
        try "---\nname: linux-tests\ndescription: Hijacked.\n---\nDo something else.\n".write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertTrue(d.model.revertOutsideEdit(edit.id, projectID: d.project))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), approved)
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty, "Claudio's own write isn't an outside edit")
        }
    }

    func testTheEditingSessionIsNamedEvenThroughItsOwnSet() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.setSessionSkillSet(d.session, ["linux-tests"])
            _ = d.model.skillSetRoot(of: d.model.workspace.session(d.session)!)
            d.model.checkSkillDrift()
            return file
        }
        let own = d.store.directory(projectID: d.project)
            .appendingPathComponent("sessions/\(d.session.uuidString.lowercased())/.claude/skills/linux-tests/SKILL.md")
        let line = d.session.uuidString + "\t" + History.json(["hook_event_name": "PostToolUse", "session_id": SkillTests.conversation,
                                                                "tool_name": "Edit", "tool_input": ["file_path": own.path]]) + "\n"
        try line.write(to: d.hookLog, atomically: true, encoding: .utf8)
        try "---\nname: linux-tests\ndescription: d\n---\nEdited by the session.\n".write(to: own, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.pollHookEvents()
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first, "edited through the link: the same file")
            XCTAssertEqual(edit.editorName, "Update PR")
            XCTAssertEqual(d.model.outsideEditLine(edit), "The Update PR session changed linux-tests/SKILL.md in Claudio's skills just now")
            XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Edited by the session."))
        }
    }

    func testADeletedSkillCanBeRestoredOrLetGo() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.setSessionSkillSet(d.session, ["linux-tests"])
            d.model.checkSkillDrift()
            return file
        }
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertTrue(edit.deleted)
            XCTAssertTrue(d.model.revertOutsideEdit(edit.id, projectID: d.project), "Restore")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            d.model.keepOutsideDeletion(edit.id, projectID: d.project)
            XCTAssertTrue(d.model.skillsData(inProject: d.project).records.isEmpty, "Claudio forgets it")
            XCTAssertNil(d.model.workspace.session(d.session)?.skillSet, "its only skill gone: the shared skills from now on")
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty)
        }
    }

    func testARepositorySkillClaudioSavedIsWatchedAndShownWithTheAssistantOff() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            _ = approveOnDisk(d)
            XCTAssertTrue(d.model.saveSkillToRepository("linux-tests", projectID: d.project))
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty, "saving it isn't an outside edit")
            d.model.setAssistantMode(.off, projectID: d.project)
            return d.repo.appendingPathComponent(".claude/skills/linux-tests/SKILL.md")
        }
        let approved = try String(contentsOf: file, encoding: .utf8)
        try (approved + "\nOne more line.\n").write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertEqual(edit.location, .repository)
            XCTAssertEqual(d.model.outsideEditLine(edit), ".claude/skills/linux-tests/SKILL.md was changed just now")
            XCTAssertEqual(d.model.needsYouCount(inProject: d.project), 1, "shown with the assistant off: sessions can edit either way")
            XCTAssertTrue(d.model.revertOutsideEdit(edit.id, projectID: d.project))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), approved, "the repository's copy is put back")
        }
    }

    func testAnEditPutBackByHandClearsTheCard() async throws {
        let d = try await makeDiskFixture()
        let (file, approved) = await MainActor.run { () -> (URL, String) in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return (file, try! String(contentsOf: file, encoding: .utf8))
        }
        try (approved + "x").write(to: file, atomically: true, encoding: .utf8)
        await MainActor.run { d.model.checkSkillDrift() }
        try approved.write(to: file, atomically: true, encoding: .utf8)
        await MainActor.run {
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty)
        }
    }

    // MARK: - Step 5b: retirement

    final class Clock: @unchecked Sendable {
        var date = SkillTests.now
    }

    func testASkillUnusedFor30DaysIsOfferedForRetiring() async throws {
        let clock = Clock()
        let f = try await makeFixture(clock: { clock.date })
        try await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            f.model.checkUnusedSkills()
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty, "approving counts as a use")
            clock.date = SkillTests.now.addingTimeInterval(29 * 86_400)
            f.model.checkUnusedSkills()
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty, "29 days")
            clock.date = SkillTests.now.addingTimeInterval(31 * 86_400)
            f.model.checkUnusedSkills()
            let unused = try XCTUnwrap(f.model.unusedSkills(inProject: f.project).first)
            XCTAssertEqual(unused.name, "linux-tests")
            XCTAssertEqual(unused.lastUsed, SkillTests.now)
            XCTAssertEqual(f.model.needsYouCount(inProject: f.project), 1)
            f.model.checkUnusedSkills()
            XCTAssertEqual(f.model.unusedSkills(inProject: f.project).count, 1, "once a day, and not twice")
            f.model.keepUnusedSkill(unused.id, projectID: f.project)
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty)
            XCTAssertEqual(f.model.skillsData(inProject: f.project).usage["linux-tests"]?.lastUsed, clock.date, "Keep counts as a use")
        }
    }

    func testNoUnusedCardsWithTheAssistantOffOrForRepositorySkills() async throws {
        let (f, repo) = try await makeRepositoryFixture()
        try writeRepositorySkill(repo, "theirs", "---\nname: theirs\ndescription: d\n---\nBody\n")
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            // Old enough: approved 40 days before the fixture's clock.
            f.model.updateSkillsData(f.project) { data in
                data.usage["linux-tests"]?.lastUsed = SkillTests.now.addingTimeInterval(-40 * 86_400)
                data.records[0].approvedAt = SkillTests.now.addingTimeInterval(-40 * 86_400)
            }
            f.model.setAssistantMode(.off, projectID: f.project)
            f.model.checkUnusedSkills()
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty, "only while the assistant is on")
            f.model.unusedSkillCheckDay = nil
            f.model.setAssistantMode(.automatic, projectID: f.project)
            f.model.checkUnusedSkills()
            XCTAssertEqual(f.model.unusedSkills(inProject: f.project).map(\.name), ["linux-tests"], "the repository's own never")
        }
    }

    func testAHandPlacedSkillGetsAStartNotACard() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            approve(f, ["by-hand"])
            f.model.checkUnusedSkills()
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty)
            XCTAssertEqual(f.model.skillsData(inProject: f.project).usage["by-hand"]?.lastUsed, SkillTests.now,
                           "no use or approval known: today is its start")
        }
    }

    func testRetireMovesTheSkillOutAndRestoreBringsItBack() async throws {
        let d = try await makeDiskFixture()
        await MainActor.run {
            let file = approveOnDisk(d)
            d.model.setSessionSkillSet(d.session, ["linux-tests"])
            XCTAssertTrue(d.model.retireSkill("linux-tests", projectID: d.project))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "out of the --add-dir root")
            let retired = d.store.directory(projectID: d.project).appendingPathComponent("retired/linux-tests/SKILL.md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: retired.path))
            XCTAssertEqual(d.model.skillsData(inProject: d.project).records.first?.location, .retired)
            XCTAssertNil(d.model.workspace.session(d.session)?.skillSet, "out of every set; its only skill gone, so the shared skills")
            XCTAssertEqual(d.model.skillRows(inProject: d.project).map(\.location), [.retired], "greyed out in Skills")
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty, "retiring isn't an outside deletion")
            XCTAssertTrue(d.model.restoreSkill("linux-tests", projectID: d.project))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(d.model.skillsData(inProject: d.project).records.first?.location, .claudio)
            XCTAssertEqual(d.model.skillRows(inProject: d.project).map(\.location), [.claudio])
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty)
        }
    }

    func testRetireFromTheCard() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            f.model.updateSkillsData(f.project) { $0.usage["linux-tests"]?.lastUsed = SkillTests.now.addingTimeInterval(-31 * 86_400) }
            f.model.findUnusedSkills(projectID: f.project)
            let unused = try XCTUnwrap(f.model.unusedSkills(inProject: f.project).first)
            XCTAssertTrue(f.model.retireUnusedSkill(unused.id, projectID: f.project))
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty)
            XCTAssertEqual(f.assistant.retired[f.project]?.map(\.name), ["linux-tests"])
            XCTAssertEqual(f.model.toast?.text, "Retired linux-tests. Restore it from Skills.")
        }
    }

    // MARK: - Step 5b: the advisor's review before the PR

    func testKeepChangeRefusesTextThatFailsTheChecks() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        let leaky = try String(contentsOf: file, encoding: .utf8) + "\nUse ghp_abcdefghijklmnopqrstuvwxyz0123456789 to push.\n"
        try leaky.write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertTrue(d.model.outsideEditProblems(edit, inProject: d.project).contains { $0.hasPrefix("it looks like it holds a secret") })
            XCTAssertFalse(d.model.keepOutsideEdit(edit.id, projectID: d.project), "only Revert is offered")
            XCTAssertEqual(d.model.skillsData(inProject: d.project).records.first?.version, 1, "not approved")
            XCTAssertFalse(d.model.log.entries.contains { ($0.detail ?? "").contains("ghp_") || $0.title.contains("ghp_") })
            XCTAssertTrue(d.model.revertOutsideEdit(edit.id, projectID: d.project))
        }
    }

    func testKeepChangeRefusesARename() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        let renamed = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "name: linux-tests", with: "name: something-else")
        try renamed.write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertEqual(d.model.outsideEditProblems(edit, inProject: d.project), ["a change renames the skill"])
        }
    }

    func testARetiredSkillsNameIsReserved() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let first = propose(f, text: SkillTests.skillText("Old."))
            XCTAssertTrue(f.model.approveSkillProposal(first.id, projectID: f.project))
            XCTAssertTrue(f.model.retireSkill("linux-tests", projectID: f.project))
            let second = propose(f, text: SkillTests.skillText("A new one with the same name."))
            XCTAssertFalse(f.model.approveSkillProposal(second.id, projectID: f.project), "it could be restored, so the name is taken")
            XCTAssertEqual(f.model.skillsData(inProject: f.project).records.map(\.location), [.retired], "the retired record is kept")
            f.model.dismissSkillProposal(second.id, projectID: f.project)
            XCTAssertTrue(f.model.restoreSkill("linux-tests", projectID: f.project), "and Restore still works")
        }
    }

    func testAnEditByHandAfterASessionsEditIsntBlamedOnIt() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        let line = d.session.uuidString + "\t" + History.json(["hook_event_name": "PostToolUse", "session_id": SkillTests.conversation,
                                                                "tool_name": "Edit", "tool_input": ["file_path": file.path]]) + "\n"
        try line.write(to: d.hookLog, atomically: true, encoding: .utf8)
        try (try String(contentsOf: file, encoding: .utf8) + "\nBy the session.\n").write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.pollHookEvents()
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertEqual(edit.editorName, "Update PR")
            XCTAssertTrue(d.model.keepOutsideEdit(edit.id, projectID: d.project))
        }
        try (try String(contentsOf: file, encoding: .utf8) + "\nBy hand, later.\n").write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.checkSkillDrift()
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertNil(edit.editorName, "the session's earlier edit was already used")
        }
    }

    func testTurningTheAssistantOnLaterThatDayStillGetsTheCheck() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            f.model.updateSkillsData(f.project) { $0.usage["linux-tests"]?.lastUsed = SkillTests.now.addingTimeInterval(-31 * 86_400) }
            f.model.setAssistantMode(.off, projectID: f.project)
            f.model.checkUnusedSkills()
            f.model.setAssistantMode(.automatic, projectID: f.project)
            f.model.checkUnusedSkills()
            XCTAssertEqual(f.model.unusedSkills(inProject: f.project).map(\.name), ["linux-tests"])
        }
    }

    // MARK: - Lessons waiting (Tim's report, 2026-10-14)

    func testWaitingLessonsAreShownAndCanBeDraftedOrDismissed() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { _ in true } }
        answerFollowUpsAndDrafts(f)
        await followUp(f, session: f.session)
        let lesson = await MainActor.run { () -> LessonCandidate in
            let waiting = f.model.waitingLessons(inProject: f.project)
            XCTAssertEqual(waiting.count, 1, "found by the follow-up, and visible while it waits")
            XCTAssertEqual(f.model.sessionsToDraft(waiting[0]), 2)
            XCTAssertTrue(f.model.draftLessonNow(waiting[0].id, projectID: f.project))
            return waiting[0]
        }
        await f.model.waitForSkillDrafts()
        await MainActor.run {
            XCTAssertEqual(f.model.skillProposals(inProject: f.project).count, 1, "Draft Now drafts it")
            XCTAssertTrue(f.model.waitingLessons(inProject: f.project).isEmpty, "it has a draft now")
            XCTAssertEqual(f.model.backgroundJobsToday, 0, "you asked for it")
            f.model.dismissSkillProposal(f.model.skillProposals(inProject: f.project)[0].id, projectID: f.project)
            XCTAssertEqual(f.model.waitingLessons(inProject: f.project).map(\.id), [lesson.id], "Not Now: back to waiting")
            f.model.dismissLesson(lesson.id, projectID: f.project)
            XCTAssertTrue(f.model.waitingLessons(inProject: f.project).isEmpty)
            XCTAssertTrue(f.model.skillsData(inProject: f.project).candidates.isEmpty, "forgotten")
        }
    }

    func testLessonsSavedByAnEarlierBuildAreRegroupedAtLaunch() async throws {
        let assistant = MemoryAssistantStore()
        let probe = try await makeFixture(assistant: assistant)
        var built = SkillsData()
        built.candidates = [
            LessonCandidate(signature: "bash for id | this session is isolated in the worktree <path> but this command runs gh with th",
                            summary: "a", evidence: [LessonEvidence(sessionID: UUID(), sessionName: "One", kind: .failure, text: "a", at: SkillTests.now)],
                            remember: false, at: SkillTests.now),
            LessonCandidate(signature: "bash do s=$(gh | this session is isolated in the worktree <path> but this command is too complex",
                            summary: "b", evidence: [LessonEvidence(sessionID: UUID(), sessionName: "Two", kind: .failure, text: "b", at: SkillTests.now)],
                            remember: false, at: SkillTests.now),
        ]
        let data = built
        await MainActor.run {
            assistant.skillsData[probe.project] = data
            probe.model.setAssistantMode(.manual, projectID: probe.project)
            probe.model.loadSkillsData()
            let saved = assistant.skillsData[probe.project]
            XCTAssertEqual(saved?.candidates.count, 1, "merged and saved")
            XCTAssertEqual(probe.model.skillOffers(inProject: probe.project).count, 1, "two sessions now: offered (Manual)")
        }
    }

    // MARK: - Review round 1 (PR #42)

    func testSaveToRepositoryWaitsForAnOutsideEditToBeResolved() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        try (try String(contentsOf: file, encoding: .utf8) + "\nUnreviewed.\n").write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            d.model.checkSkillDrift()
            XCTAssertFalse(d.model.saveSkillToRepository("linux-tests", projectID: d.project))
            XCTAssertEqual(d.model.toast?.text, "linux-tests was changed outside Claudio. Keep or revert that change first.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: d.repo.appendingPathComponent(".claude/skills/linux-tests").path))
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertTrue(d.model.revertOutsideEdit(edit.id, projectID: d.project))
            XCTAssertTrue(d.model.saveSkillToRepository("linux-tests", projectID: d.project), "once it's resolved")
        }
    }

    func testAStaleCardCantPutASavedSkillBackIntoClaudio() async throws {
        let d = try await makeDiskFixture()
        await MainActor.run {
            _ = approveOnDisk(d)
            // A card left over from before the skill was saved to the repository.
            let stale = OutsideEdit(name: "linux-tests", location: .claudio, deleted: false, foundHash: "x", foundAt: SkillTests.now)
            XCTAssertTrue(d.model.saveSkillToRepository("linux-tests", projectID: d.project))
            d.model.updateSkillsData(d.project) { $0.outsideEdits.append(stale) }
            XCTAssertFalse(d.model.revertOutsideEdit(stale.id, projectID: d.project))
            XCTAssertNil(d.store.approvedSkillFile(name: "linux-tests", projectID: d.project).flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }, "not loaded twice")
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty, "the stale card goes")
        }
    }

    func testAFileThatCantBeReachedIsntTakenForDeleted() async throws {
        let d = try await makeDiskFixture()
        let (file, skills) = await MainActor.run { () -> (URL, URL) in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return (file, file.deletingLastPathComponent().deletingLastPathComponent())
        }
        // The whole skills folder unreachable (a drive that isn't mounted, say).
        let aside = skills.deletingLastPathComponent().appendingPathComponent("skills-aside")
        try FileManager.default.moveItem(at: skills, to: aside)
        await MainActor.run {
            d.model.checkSkillDrift()
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty, "can't tell: no deletion card")
            XCTAssertTrue(d.model.log.entries.contains { $0.title == "Couldn't check linux-tests for edits made outside Claudio" })
        }
        try FileManager.default.moveItem(at: aside, to: skills)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        await MainActor.run {
            d.model.checkSkillDrift()
            XCTAssertEqual(d.model.outsideEdits(inProject: d.project).first?.deleted, true, "really gone, with its folder reachable")
        }
    }

    func testAFileThatIsntUTF8IsAChangeNotAFailure() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        var bytes = try Data(contentsOf: file)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x0A])
        try bytes.write(to: file)
        await MainActor.run {
            d.model.checkSkillDrift()
            XCTAssertEqual(d.model.outsideEdits(inProject: d.project).count, 1)
        }
    }

    func testKeepChangeOnlyKeepsWhatTheCardShowed() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        let approved = try String(contentsOf: file, encoding: .utf8)
        try (approved + "\nOne line.\n").write(to: file, atomically: true, encoding: .utf8)
        await MainActor.run { d.model.checkSkillDrift() }
        try (approved + "\nA whole rewrite, after the card.\n").write(to: file, atomically: true, encoding: .utf8)
        try await MainActor.run {
            let edit = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertFalse(d.model.keepOutsideEdit(edit.id, projectID: d.project))
            XCTAssertEqual(d.model.toast?.text, "linux-tests changed again since this card. Review the new change.")
            XCTAssertEqual(d.model.skillsData(inProject: d.project).records.first?.version, 1, "nothing kept")
            d.model.checkSkillDrift()
            let fresh = try XCTUnwrap(d.model.outsideEdits(inProject: d.project).first)
            XCTAssertNotEqual(fresh.foundHash, edit.foundHash, "a fresh card for the new change")
            XCTAssertTrue(d.model.keepOutsideEdit(fresh.id, projectID: d.project))
        }
    }

    func testRetireAndRestoreWaitForAReadableSkillsFile() async throws {
        let f = try await makeFixture()
        await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            f.model.unreadableSkillsData.insert(f.project)
            XCTAssertFalse(f.model.retireSkill("linux-tests", projectID: f.project))
            XCTAssertEqual(f.assistant.skills[f.project]?.map(\.name), ["linux-tests"], "not moved")
            f.model.unreadableSkillsData.remove(f.project)
            XCTAssertTrue(f.model.retireSkill("linux-tests", projectID: f.project))
            f.model.unreadableSkillsData.insert(f.project)
            XCTAssertFalse(f.model.restoreSkill("linux-tests", projectID: f.project))
            XCTAssertEqual(f.assistant.retired[f.project]?.map(\.name), ["linux-tests"], "still retired")
        }
    }

    func testAUseWithdrawsAnUnusedCard() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            f.model.updateSkillsData(f.project) { $0.usage["linux-tests"]?.lastUsed = SkillTests.now.addingTimeInterval(-31 * 86_400) }
            f.model.findUnusedSkills(projectID: f.project)
            let card = try XCTUnwrap(f.model.unusedSkills(inProject: f.project).first)
            // Used since, by a hook the card didn't see.
            f.model.updateSkillsData(f.project) { $0.usage["linux-tests"]?.lastUsed = SkillTests.now }
            XCTAssertFalse(f.model.retireUnusedSkill(card.id, projectID: f.project))
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty, "the card goes")
            XCTAssertEqual(f.assistant.skills[f.project]?.map(\.name), ["linux-tests"], "still loaded")
        }
        try writeHooks([["hook_event_name": "UserPromptSubmit", "session_id": SkillTests.conversation, "prompt": "/linux-tests"]], f)
        await MainActor.run {
            f.model.updateSkillsData(f.project) { $0.unusedSkills.append(UnusedSkill(name: "linux-tests", lastUsed: SkillTests.now, foundAt: SkillTests.now)) }
            f.model.pollHookEvents()
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty, "a use withdraws it")
        }
    }

    func testRemovingLinksNeverTouchesTheApprovedSkills() throws {
        let store = AssistantFileStore(root: try makeTemporaryDirectory())
        let project = UUID(), session = UUID()
        for name in ["a-skill", "b-skill"] {
            try store.writeApprovedSkill(name: name, text: "---\nname: \(name)\n---\n", projectID: project)
        }
        _ = try store.sessionSkillsRoot(projectID: project, sessionID: session, skills: ["a-skill", "b-skill"])
        _ = try store.sessionSkillsRoot(projectID: project, sessionID: session, skills: ["b-skill"])
        XCTAssertEqual(store.approvedSkills(projectID: project).map(\.name), ["a-skill", "b-skill"], "a removed link leaves its skill")
        try store.removeSessionSkillsRoot(projectID: project, sessionID: session)
        XCTAssertEqual(store.approvedSkills(projectID: project).map(\.name), ["a-skill", "b-skill"], "so does removing the root")
        XCTAssertEqual(store.sessionSkillsRootIDs(projectID: project), [])
    }

    func testRetireTakesASessionsLinkAndRestoreKeepsItOut() async throws {
        let d = try await makeDiskFixture()
        await MainActor.run {
            _ = approveOnDisk(d)
            let other = SkillProposal(candidateID: nil, name: "other-skill",
                                      text: SkillText.compose(name: "other-skill", description: "d", whenToUse: "", paths: [], body: "b", metadata: []),
                                      previousText: nil, why: "w", createdAt: SkillTests.now, model: "Sonnet")
            d.model.updateSkillsData(d.project) { $0.proposals.append(other) }
            XCTAssertTrue(d.model.approveSkillProposal(other.id, projectID: d.project))
            d.model.setSessionSkillSet(d.session, ["linux-tests", "other-skill"])
            let root = d.model.skillSetRoot(of: d.model.workspace.session(d.session)!)!
            XCTAssertEqual(SkillFiles.approved(inRoot: root).map(\.name), ["linux-tests", "other-skill"])
            XCTAssertTrue(d.model.retireSkill("linux-tests", projectID: d.project))
            XCTAssertEqual(SkillFiles.approved(inRoot: root).map(\.name), ["other-skill"], "the retired skill's link is gone")
            XCTAssertTrue(d.model.restoreSkill("linux-tests", projectID: d.project))
            XCTAssertEqual(SkillFiles.approved(inRoot: root).map(\.name), ["other-skill"], "restoring doesn't add it back to a set")
        }
    }

    func testABackgroundResumeUsesItsOwnSetAndContinuingOneTakesNoFlags() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            approve(f, ["a-skill"])
            f.model.setSessionSkillSet(f.session, ["a-skill"])
            let session = try XCTUnwrap(f.model.workspace.session(f.session))
            let launch = try XCTUnwrap(f.model.assistantLaunch(for: session))
            let own = "/memory/\(f.project.uuidString.lowercased())/sessions/\(f.session.uuidString.lowercased())"
            XCTAssertEqual(launch.skillsRoot, own, "every launch path reads the session")
        }
    }

    func testASetThatCantBeBuiltFallsBackAndSaysSo() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        await MainActor.run {
            approve(f, ["a-skill"])
            f.model.setSessionSkillSet(f.session, ["a-skill"])
            assistant.sessionSkillsError = CocoaError(.fileWriteNoPermission)
            XCTAssertNil(f.model.skillSetRoot(of: f.model.workspace.session(f.session)!))
            XCTAssertEqual(f.model.toast?.text, "Couldn't set up Shell Height's own skills, so it loads every approved skill. See the Activity Log.")
        }
    }

    func testADeletedSessionsLeftoverSetIsTidiedAtLaunch() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        await MainActor.run {
            let gone = UUID()
            assistant.sessionRootProjects[gone] = f.project
            assistant.sessionRootProjects[f.session] = f.project
            f.model.syncSkillSets()
            XCTAssertNil(assistant.sessionRootProjects[gone], "no session owns it")
            XCTAssertNotNil(assistant.sessionRootProjects[f.session], "a session that exists keeps its own")
        }
    }

    func testTheUnusedCheckRunsOnceADay() async throws {
        let clock = Clock()
        let f = try await makeFixture(clock: { clock.date })
        try await MainActor.run {
            let proposal = propose(f, text: SkillTests.skillText("Run it."))
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            clock.date = SkillTests.now.addingTimeInterval(31 * 86_400)
            f.model.checkUnusedSkills()
            let card = try XCTUnwrap(f.model.unusedSkills(inProject: f.project).first)
            f.model.keepUnusedSkill(card.id, projectID: f.project)
            // Stale again, the same day: the check has run today.
            f.model.updateSkillsData(f.project) { $0.usage["linux-tests"]?.lastUsed = SkillTests.now }
            f.model.checkUnusedSkills()
            XCTAssertTrue(f.model.unusedSkills(inProject: f.project).isEmpty, "once a day")
            clock.date = clock.date.addingTimeInterval(86_400)
            f.model.checkUnusedSkills()
            XCTAssertEqual(f.model.unusedSkills(inProject: f.project).count, 1, "the next day")
        }
    }

    func testAVersion1FileRoundTripsThroughTheFileStore() throws {
        let store = AssistantFileStore(root: try makeTemporaryDirectory())
        let project = UUID()
        let folder = store.directory(projectID: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let v1 = #"{"version":1,"usage":{"a":{"sessions":["6F9619FF-8B86-D011-B42D-00C04FC964FF"],"lastUsed":"2026-10-01T10:00:00Z"}},"candidates":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","signature":"bash make | boom","summary":"s","evidence":[],"remember":false,"state":"collecting","heldUntilSessions":3,"createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z"},{"broken":true}],"proposals":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FD","name":"a","text":"t","why":"w","createdAt":"2026-10-01T10:00:00Z","model":"Sonnet"}],"records":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FC","name":"a","version":2,"approvedAt":"2026-10-01T10:00:00Z","contentHash":"h"}]}"#
        try v1.write(to: folder.appendingPathComponent("skills.json"), atomically: true, encoding: .utf8)
        let data = try store.loadSkillsData(projectID: project)
        XCTAssertEqual(data.usage["a"]?.sessions.count, 1)
        XCTAssertEqual(data.candidates.first?.heldUntilSessions, 3)
        XCTAssertEqual(data.proposals.first?.name, "a")
        XCTAssertEqual(data.records.first?.location, .claudio)
        XCTAssertEqual(data.unreadableCount, 1)
        try store.saveSkillsData(data, projectID: project)
        let again = try store.loadSkillsData(projectID: project)
        XCTAssertEqual(again, data, "nothing lost, the unreadable entry included")
        let saved = try String(contentsOf: folder.appendingPathComponent("skills.json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("\"broken\""))
    }

    // MARK: - Review round 2 (PR #42)

    func testAnEditTheDriftCheckHasntSeenStillStopsSaveToRepository() async throws {
        let d = try await makeDiskFixture()
        let file = await MainActor.run { () -> URL in
            let file = approveOnDisk(d)
            d.model.checkSkillDrift()
            return file
        }
        // Edited moments ago: no drift check has run since, so no card yet.
        try (try String(contentsOf: file, encoding: .utf8) + "\nJust now.\n").write(to: file, atomically: true, encoding: .utf8)
        await MainActor.run {
            XCTAssertTrue(d.model.outsideEdits(inProject: d.project).isEmpty, "no card yet")
            XCTAssertFalse(d.model.saveSkillToRepository("linux-tests", projectID: d.project))
            XCTAssertEqual(d.model.toast?.text, "linux-tests was changed outside Claudio. Keep or revert that change first.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: d.repo.appendingPathComponent(".claude/skills/linux-tests").path),
                           "the unchecked text isn't copied")
            d.model.checkSkillDrift()
            XCTAssertEqual(d.model.outsideEdits(inProject: d.project).count, 1, "and the next check raises its card")
        }
    }
}
