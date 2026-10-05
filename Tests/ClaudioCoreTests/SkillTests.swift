import XCTest
@testable import ClaudioCore

/// Answers assistant calls with whatever `answer` gives for their arguments,
/// and everything else as `FakeRunner` does.
final class SkillRunner: CommandRunning, @unchecked Sendable {
    let base = FakeRunner()
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _answer: ([String]) -> CommandResult = { _ in CommandResult(exitCode: 1, output: "", errorOutput: "no answer set") }

    var calls: [[String]] { lock.withLock { _calls } }
    var answer: ([String]) -> CommandResult {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        let args = command.claudeArguments
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
                     clock: @escaping () -> Date = { SkillTests.now }) async throws -> Fixture {
        let runner = SkillRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        let claudeHome = try makeTemporaryDirectory()
        let directory = claudeHome.appendingPathComponent("projects/-code-app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("\(SkillTests.conversation).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: history, atomically: true, encoding: .utf8)
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let session = Session(projectID: project, claudeSessionID: SkillTests.conversation, hasConversation: true, name: "Shell Height",
                              workingDirectory: "/code/app", status: .completed, lastActivity: SkillTests.now.addingTimeInterval(-600))
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

    func testCommandsOffThePathFailTheChecks() async throws {
        let f = try await makeFixture()
        await MainActor.run { f.model.commandExistsOverride = { $0 != "frobnicate" } }
        let draft = #"{"action":"new","skill":null,"name":"frob","description":"Frob.","whenToUse":"","paths":[],"body":"```bash\nfrobnicate --all\n```","why":"x"}"#
        answerFollowUpsAndDrafts(f, draft: draft, remember: true)
        await followUp(f, session: f.session, remember: true)
        await MainActor.run {
            XCTAssertTrue(f.model.skillProposals(inProject: f.project).isEmpty)
            XCTAssertEqual(f.model.log.entries.last { $0.title.contains("dropped a skill draft") }?.detail,
                           "it runs frobnicate, which isn't on the PATH")
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
            let proposal = propose(f, text: SkillTests.skillText("New.", version: 3), previous: old)
            XCTAssertTrue(f.model.approveSkillProposal(proposal.id, projectID: f.project))
            let skill = f.model.approvedSkills[f.project]?.first
            XCTAssertEqual(skill?.version, 3)
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
            XCTAssertEqual(f.model.editSkillProposal(proposal.id, text: leaky, projectID: f.project),
                           ["it looks like it holds a secret (a GitHub token)"])
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
}
