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
}
