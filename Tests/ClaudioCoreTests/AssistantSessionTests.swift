import XCTest
@testable import ClaudioCore

/// Step 3 of the Project Assistant: the opening prompt, skills and chips,
/// the launch flags, Claudio's plugin, and notes from sessions.
final class AssistantSessionTests: XCTestCase {
    // MARK: - Opening prompt

    func testOpeningPromptHasTheTitleNotesIssueAndSkills() {
        let text = OpeningPrompt.text(title: "Remember Shell panel height per project",
                                      notes: ["Resets on relaunch.", "Store it per project,\nnot globally.", "  "],
                                      issue: "#17", skills: ["worktree-setup", "shell-panel-code-map"])
        XCTAssertEqual(text, """
            Remember Shell panel height per project

            Notes:
            - Resets on relaunch.
            - Store it per project,
              not globally.

            GitHub issue: #17

            Use these skills: /worktree-setup, /shell-panel-code-map
            """)
    }

    func testOpeningPromptWithoutNotesOrSkillsIsJustTheTitle() {
        XCTAssertEqual(OpeningPrompt.text(title: "Tidy the README", notes: [], issue: nil, skills: []), "Tidy the README",
                       "no filler line is sent to Claude")
    }

    // MARK: - Skills

    func testGlobMatching() {
        XCTAssertTrue(Glob.matches("Sources/**/*.swift", "Sources/ClaudioCore/Assistant.swift"))
        XCTAssertTrue(Glob.matches("Sources/**/*.swift", "Sources/a.swift"), "** matches no folders too")
        XCTAssertFalse(Glob.matches("Sources/*.swift", "Sources/ClaudioCore/Assistant.swift"), "* stays in its folder")
        XCTAssertTrue(Glob.matches("*.md", "design/Project Assistant Backend.md"), "a name pattern matches in any folder")
        XCTAssertTrue(Glob.matches("scripts/build-?pp.sh", "scripts/build-app.sh"))
        XCTAssertFalse(Glob.matches("Tests/**", "Sources/a.swift"))
        XCTAssertTrue(Glob.matches("Tests/**", "Tests/ClaudioCoreTests/Fixtures/a.json"))
    }

    func testFrontmatterForms() {
        let skill = SkillFiles.skill(fromSkillFile: """
            ---
            name: shell-panel-code-map
            description: "Where the Shell panel's code lives."
            paths:
              - Sources/Claudio/ShellPanelViews.swift
              - 'Sources/ClaudioCore/Shell*.swift'
            metadata:
              claudio-id: 1234
              claudio-folders: [In-built Shell, Terminal]
            ---
            # Body
            name: not-this
            """, folderName: "folder-name")
        XCTAssertEqual(skill, ApprovedSkill(name: "shell-panel-code-map", description: "Where the Shell panel's code lives.",
                                            paths: ["Sources/Claudio/ShellPanelViews.swift", "Sources/ClaudioCore/Shell*.swift"],
                                            folders: ["In-built Shell", "Terminal"]))
        let plain = SkillFiles.skill(fromSkillFile: "---\ndescription: x\npaths: a/*.swift, b/**\n---\n", folderName: "readme-style")
        XCTAssertEqual(plain.name, "readme-style", "the folder's name without a name field")
        XCTAssertEqual(plain.paths, ["a/*.swift", "b/**"])
        XCTAssertEqual(SkillFiles.skill(fromSkillFile: "No frontmatter", folderName: "x"), ApprovedSkill(name: "x"))
    }

    func testApprovedSkillsAreReadFromTheSkillsRoot() throws {
        let root = try makeTemporaryDirectory()
        let skills = root.appendingPathComponent(".claude/skills")
        for (name, text) in [("b-skill", "---\nname: b-skill\n---\n"), ("a-skill", "---\nname: a-skill\n---\n")] {
            try FileManager.default.createDirectory(at: skills.appendingPathComponent(name), withIntermediateDirectories: true)
            try text.write(to: skills.appendingPathComponent(name).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: skills.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertEqual(SkillFiles.approved(inRoot: root).map(\.name), ["a-skill", "b-skill"], "sorted; a folder without SKILL.md is skipped")
        XCTAssertEqual(SkillFiles.approved(inRoot: root.appendingPathComponent("missing")), [])
    }

    func testChipsScoreByFilesFolderAndUse() {
        let skills = [
            ApprovedSkill(name: "shell-map", paths: ["Sources/**/Shell*.swift"]),
            ApprovedSkill(name: "worktree-setup", folders: ["In-built Shell"]),
            ApprovedSkill(name: "readme-style", paths: ["README.md"]),
            ApprovedSkill(name: "pr-review"),
            ApprovedSkill(name: "used-a-lot"),
        ]
        let picked = SkillChips.pick(from: skills, touchedFiles: ["Sources/Claudio/ShellPanelViews.swift", "Sources/x.swift"],
                                     folderName: "in-built shell", usage: ["used-a-lot": 1])
        XCTAssertEqual(picked.map(\.name), ["shell-map", "worktree-setup", "used-a-lot"],
                       "files first, then the folder, then use; skills that score nothing aren't picked")
        XCTAssertEqual(SkillChips.pick(from: skills, touchedFiles: [], folderName: nil), [])
        let many = (1...5).map { ApprovedSkill(name: "s\($0)", folders: ["F"]) }
        XCTAssertEqual(SkillChips.pick(from: many, touchedFiles: [], folderName: "F").count, SkillChips.limit)
    }

    func testRelativePathsIncludeWorktrees() {
        XCTAssertEqual(SkillChips.relativePath("/code/app/Sources/a.swift", projectPath: "/code/app"), "Sources/a.swift")
        XCTAssertEqual(SkillChips.relativePath("/code/app/.claude/worktrees/fix-1/Sources/a.swift", projectPath: "/code/app/"),
                       "Sources/a.swift")
        XCTAssertNil(SkillChips.relativePath("/code/application/a.swift", projectPath: "/code/app"))
    }

    // MARK: - Launch flags

    private let assistant = AssistantLaunch(pluginDirectory: "/Support/Claudio/plugin/claudio",
                                            skillsRoot: "/Support/Claudio/assistant/p/skills")

    private func commands() -> AgentCommands {
        AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/tmp/h.log",
                      baseEnvironment: ["HOME": "/Users/tim", "PATH": "/usr/bin"])
    }

    func testNewSessionsGetThePluginAndSkillsFlags() {
        let session = Session(projectID: UUID(), name: "s", workingDirectory: "/code/app")
        let dispatch = commands().dispatch(session: session, prompt: "Fix it", isolation: .worktree, assistant: assistant).claudeArguments
        XCTAssertTrue(dispatch.containsSequence(["--plugin-dir", "/Support/Claudio/plugin/claudio"]))
        XCTAssertTrue(dispatch.containsSequence(["--add-dir", "/Support/Claudio/assistant/p/skills"]))
        XCTAssertEqual(Array(dispatch.suffix(2)), ["--", "Fix it"], "the prompt stays last, after --")

        let direct = TerminalLaunch.make(session: session, claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh",
                                         initialPrompt: nil, hookEventsPath: "/tmp/h.log", assistant: assistant)
        XCTAssertTrue(direct.claudeArguments.contains("--session-id"))
        XCTAssertTrue(direct.claudeArguments.containsSequence(["--plugin-dir", "/Support/Claudio/plugin/claudio"]))
        XCTAssertTrue(direct.claudeArguments.containsSequence(["--add-dir", "/Support/Claudio/assistant/p/skills"]))

        // In Ask mode, `claudio` needs a rule to run without a prompt.
        XCTAssertEqual(allowRules(dispatch), ["Bash(claudio:*)"])
        XCTAssertEqual(allowRules(direct.claudeArguments), ["Bash(claudio:*)"])
        let plain = commands().dispatch(session: session, prompt: "Fix it", isolation: .worktree).claudeArguments
        XCTAssertNil(allowRules(plain), "no plugin, no rule")
        let resumed = TerminalLaunch.make(session: Session(projectID: UUID(), hasConversation: true, name: "s", workingDirectory: "/c"),
                                          claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", initialPrompt: nil,
                                          hookEventsPath: "/tmp/h.log", assistant: assistant)
        XCTAssertNil(allowRules(resumed.claudeArguments))
    }

    /// `permissions.allow` from the `--settings` JSON.
    private func allowRules(_ arguments: [String]) -> [String]? {
        guard let index = arguments.firstIndex(of: "--settings"), index + 1 < arguments.count,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments[index + 1].utf8))
        else { return nil }
        return json["permissions"]?["allow"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// Resuming a background agent with flags starts a copy, so the flags
    /// are only ever given at launch.
    func testResumingNeverAddsTheFlags() {
        var session = Session(projectID: UUID(), claudeSessionID: "0f0e", hasConversation: true, name: "s",
                              workingDirectory: "/code/app")
        session.agentID = "0f0e0d0c"
        for resumed in [commands().resume(session: session, prompt: "next", continuingAgent: true),
                        commands().resume(session: session, prompt: "next", continuingAgent: false)] {
            XCTAssertFalse(resumed.claudeArguments.contains("--plugin-dir"))
            XCTAssertFalse(resumed.claudeArguments.contains("--add-dir"))
        }
        let direct = TerminalLaunch.make(session: session, claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh",
                                         initialPrompt: nil, hookEventsPath: "/tmp/h.log", assistant: assistant)
        XCTAssertTrue(direct.claudeArguments.contains("--resume"))
        XCTAssertFalse(direct.claudeArguments.contains("--plugin-dir"), "a direct --resume doesn't get them either")
    }

    func testSessionsFromOlderStateHaveNoAssistant() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00C04FC964FE","name":"old","workingDirectory":"/code","createdAt":"2026-09-01T10:00:00Z"}"#
        let session = try JSONFileStore.decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertFalse(session.hasAssistant)
        XCTAssertEqual(session.namedSkills, [])
        var started = session
        started.hasAssistant = true
        started.namedSkills = ["worktree-setup"]
        let again = try JSONFileStore.decoder.decode(Session.self, from: JSONFileStore.encoder.encode(started))
        XCTAssertTrue(again.hasAssistant)
        XCTAssertEqual(again.namedSkills, ["worktree-setup"])
    }

    /// Items no longer have a folder; a step 2 file's `folderID` is ignored.
    func testAnItemsOldFolderIsIgnored() throws {
        let json = #"{"version":2,"mode":"automatic","notes":[],"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","status":"planned","folderID":"6F9619FF-8B86-D011-B42D-00C04FC964FE","createdAt":"2026-09-01T10:00:00Z"}]}"#
        let data = try JSONFileStore.decoder.decode(AssistantData.self, from: Data(json.utf8))
        XCTAssertEqual(data.items.map(\.title), ["Old"])
        XCTAssertEqual(data.unreadableCount, 0)
        let saved = String(decoding: try JSONFileStore.encoder.encode(data), as: UTF8.self)
        XCTAssertFalse(saved.contains("folderID"))
    }

    // MARK: - Plugin

    func testPluginInstallsOnceAndRepairsChanges() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("plugin/claudio")
        XCTAssertTrue(try ClaudioPlugin.install(at: directory))
        let command = directory.appendingPathComponent("bin/claudio")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".claude-plugin/plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("skills/note/SKILL.md").path))
        XCTAssertFalse(try ClaudioPlugin.install(at: directory), "already as it should be")

        try "echo edited".write(to: command, atomically: true, encoding: .utf8)
        try "stray".write(to: directory.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try ClaudioPlugin.install(at: directory), "a changed file is put back")
        XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), ClaudioPlugin.command)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stray.txt").path),
                       "replaced whole")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["claudio"], "no staging folder left behind")
    }

    func testTheNoteSkillIsNamedNote() {
        let skill = SkillFiles.skill(fromSkillFile: ClaudioPlugin.noteSkill, folderName: "x")
        XCTAssertEqual(skill.name, "note")
        XCTAssertLessThanOrEqual(skill.description.count, 1536, "the listing cuts longer descriptions")
    }

    // MARK: - bin/claudio

    /// A Claudio folder laid out as Application Support is, under a path
    /// with a space in it, and the plugin written into it.
    private struct CommandFixture {
        let support: URL
        let assistant: URL
        let command: URL
        let repo: URL
        let projectID = UUID()
    }

    private func makeCommandFixture() throws -> CommandFixture {
        let support = try makeTemporaryDirectory().appendingPathComponent("Application Support/Claudio")
        let assistant = support.appendingPathComponent("assistant")
        let plugin = support.appendingPathComponent("plugin/claudio")
        try ClaudioPlugin.install(at: plugin)
        let repo = try makeTemporaryDirectory().appendingPathComponent("my app")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".claude/worktrees/fix-1"),
                                                withIntermediateDirectories: true)
        let fixture = CommandFixture(support: support, assistant: assistant, command: plugin.appendingPathComponent("bin/claudio"),
                                     repo: repo.resolvingSymlinksInPath())
        let store = AssistantFileStore(root: assistant)
        let project = Project(id: fixture.projectID, name: "my app", path: fixture.repo.path, folders: [])
        let other = Project(id: UUID(), name: "other", path: "/nowhere/else", folders: [])
        try store.writeIndex(AssistantIndex.text(projects: [other, project]))
        var data = AssistantData()
        let item = PlanItem(id: UUID(uuidString: "AB12CD34-0000-0000-0000-000000000000")!, title: "Remember panel height",
                            status: .planned, createdAt: Date())
        data.items = [item, PlanItem(title: "Dark icon", status: .idea, createdAt: Date())]
        data.notes = [ProjectNote(text: "Resets on relaunch.\nEvery time.", author: .user, createdAt: Date(), itemID: item.id)]
        try store.writePlanSnapshot(PlanSnapshot.text(projectName: "my app", data: data) { _ in nil }, projectID: fixture.projectID)
        return fixture
    }

    private func runCommand(_ fixture: CommandFixture, _ arguments: [String], in directory: URL,
                            session: String? = "c0ffee00-1111-2222-3333-444455556666", stdin: String? = nil) throws
        -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [fixture.command.path] + arguments
        process.currentDirectoryURL = directory
        // Only what's set here: the test itself may run inside a Claude Code session.
        var environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "PWD": directory.path]
        if let session { environment["CLAUDE_CODE_SESSION_ID"] = session }
        process.environment = environment
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, error)
    }

    func testCommandWritesNotesToTheInbox() throws {
        let f = try makeCommandFixture()
        let worktree = f.repo.appendingPathComponent(".claude/worktrees/fix-1")
        let saved = try runCommand(f, ["note", "Don't use `--worktree`: it's \"blocked\"; see $HOME"], in: worktree)
        XCTAssertEqual(saved.status, 0, saved.error)
        XCTAssertEqual(saved.output, "Saved to the project's notes in Claudio.\n")
        XCTAssertEqual(try runCommand(f, ["note", "-"], in: f.repo, session: nil, stdin: "From stdin,\nover two lines\n").status, 0)
        XCTAssertEqual(try runCommand(f, ["note", "   "], in: f.repo).status, 2, "a blank note is refused")

        let lines = AssistantFileStore(root: f.assistant).takeInbox()
        XCTAssertEqual(lines.compactMap(InboxEntry.parse), [
            InboxEntry(sessionID: "c0ffee00-1111-2222-3333-444455556666", directory: worktree.path, command: "note",
                       text: "Don't use `--worktree`: it's \"blocked\"; see $HOME"),
            InboxEntry(sessionID: "", directory: f.repo.path, command: "note", text: "From stdin,\nover two lines"),
        ])
    }

    func testCommandPrintsThePlanAndAnItem() throws {
        let f = try makeCommandFixture()
        let plan = try runCommand(f, ["plan"], in: f.repo.appendingPathComponent(".claude/worktrees/fix-1"))
        XCTAssertEqual(plan.status, 0, plan.error)
        XCTAssertTrue(plan.output.contains("- [ab12cd34] Remember panel height"), plan.output)
        XCTAssertTrue(plan.output.contains("Dark icon"))
        XCTAssertFalse(plan.output.contains("Resets on relaunch"), "notes are left out of the plan")

        let item = try runCommand(f, ["item", "ab12cd34"], in: f.repo)
        XCTAssertEqual(item.output, "- [ab12cd34] Remember panel height\n  - You: Resets on relaunch.\n    Every time.\n")
        XCTAssertEqual(try runCommand(f, ["item", "ffffffff"], in: f.repo).status, 1)

        let outside = try runCommand(f, ["plan"], in: try makeTemporaryDirectory())
        XCTAssertEqual(outside.status, 1)
        XCTAssertTrue(outside.error.contains("no plan"), outside.error)
    }

    // MARK: - Inbox

    func testInboxEntriesParse() {
        let text = Data("A note\twith a tab".utf8).base64EncodedString()
        XCTAssertEqual(InboxEntry.parse("sid\t/code/app\tnote\t\(text)"),
                       InboxEntry(sessionID: "sid", directory: "/code/app", command: "note", text: "A note\twith a tab"))
        XCTAssertNil(InboxEntry.parse("sid\t/code/app\tnote\tnot base64!"))
        XCTAssertNil(InboxEntry.parse("too\tfew"))
    }

    func testInboxReaderTakesWholeLinesOnceAcrossLaunches() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("inbox.log")
        XCTAssertEqual(InboxReader(url: url).take(), [], "no inbox yet")
        try "one\ntwo\nthr".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(InboxReader(url: url).take(), ["one", "two"], "a line still being written waits")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ee\n".utf8))
        try handle.close()
        XCTAssertEqual(InboxReader(url: url).take(), ["three"], "a new reader (a relaunch) goes on from the saved place")
        XCTAssertEqual(InboxReader(url: url).take(), [])
        try "new\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(InboxReader(url: url).take(), ["new"], "a replaced, shorter file is read from the top")
    }

    // MARK: - The model

    @MainActor private func makeFixture(assistant: AssistantStoring = MemoryAssistantStore(), runner: FakeRunner = FakeRunner())
        throws -> (AppModel, UUID, UUID, Session) {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let session = Session(projectID: project, claudeSessionID: "c0ffee00-1111-2222-3333-444455556666", hasConversation: true,
                              name: "Shell Follow Up", workingDirectory: "/code/app", status: .awaitingInput)
        try state.workspace.addSession(session)
        let folder = try state.workspace.createFolder(in: project, named: "In-built Shell", containing: session.id)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             runner: runner, assistantStore: assistant,
                             locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil },
                             isGitRepository: { $0 == "/code/app" }, shell: "/bin/sh", home: "/")
        return (model, project, folder, session)
    }

    private func line(_ session: String, _ directory: String, _ text: String) -> String {
        "\(session)\t\(directory)\tnote\t\(Data(text.utf8).base64EncodedString())"
    }

    func testSessionNotesAreSavedAsTheSessionAndJoinItsItem() throws {
        try MainActor.assumeIsolated {
            let assistant = MemoryAssistantStore()
            let (model, project, _, session) = try makeFixture(assistant: assistant)
            let note = try XCTUnwrap(model.addNote("Panel height", author: .user, projectID: project, sessionID: nil))
            let item = try XCTUnwrap(model.promoteNote(note.id, projectID: project))
            model.startSessionForTest(item: item.id, session: session.id, projectID: project)

            assistant.inbox = [
                line("c0ffee00-1111-2222-3333-444455556666", "/code/app/.claude/worktrees/fix-1", "Found by Claude Code's id."),
                line(session.id.uuidString, "/code/app", "Found by Claudio's id (a direct tab)."),
                line("", "/code/app/Sources", "No session: found by its folder."),
                line("", "/elsewhere", "Outside every project."),
                "not a line",
            ]
            model.pollAssistantInbox()
            let notes = model.notes(inProject: project)
            XCTAssertEqual(notes.map(\.text), ["No session: found by its folder.", "Found by Claudio's id (a direct tab).",
                                               "Found by Claude Code's id.", "Panel height"])
            XCTAssertEqual(notes.prefix(3).map(\.author), [.session, .session, .session])
            XCTAssertEqual(notes.prefix(3).map(\.sessionID), [nil, session.id, session.id])
            XCTAssertEqual(notes.prefix(3).map(\.itemID), [nil, item.id, item.id], "the session's own item")
            XCTAssertTrue(notes[0].canUndo)
            XCTAssertEqual(model.metaLine(for: notes[1]).components(separatedBy: " · ").first, "Shell Follow Up")
            XCTAssertEqual(assistant.audit[project]?.last?.actor, .session)
            XCTAssertEqual(assistant.inbox, [], "taken")
        }
    }

    func testPlanSnapshotAndIndexFollowChanges() throws {
        try MainActor.assumeIsolated {
            let assistant = MemoryAssistantStore()
            let (model, project, _, _) = try makeFixture(assistant: assistant)
            XCTAssertEqual(assistant.index, "/code/app\t\(project.uuidString.lowercased())\n", "written at launch")
            XCTAssertTrue(assistant.planSnapshots[project]?.contains("The plan is empty.") ?? false)
            let note = try XCTUnwrap(model.addNote("Dark icon", author: .user, projectID: project, sessionID: nil))
            let item = try XCTUnwrap(model.promoteNote(note.id, projectID: project, status: .idea))
            XCTAssertTrue(assistant.planSnapshots[project]?.contains("- [\(PlanSnapshot.shortID(item.id))] Dark icon") ?? false)
            let added = model.addProject(path: "/code/other")
            XCTAssertTrue(assistant.index?.contains("/code/other\t\(added.uuidString.lowercased())") ?? false)
        }
    }

    func testStartSessionFromAnItem() async throws {
        let runner = FakeRunner()
        let support = try makeTemporaryDirectory()
        let (model, project, folder, itemID, skillsRoot) = try await MainActor.run {
            () -> (AppModel, UUID, UUID, UUID, URL) in
            let store = AssistantFileStore(root: support.appendingPathComponent("assistant"))
            let (model, project, folder, session) = try makeFixture(assistant: store, runner: runner)
            let skillsRoot = try XCTUnwrap(store.skillsRoot(projectID: project))
            let skill = skillsRoot.appendingPathComponent(".claude/skills/shell-map")
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: shell-map\nmetadata:\n  claudio-folders: [In-built Shell]\n---\n"
                .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let first = try XCTUnwrap(model.addNote("Shell panel height resets", author: .user, projectID: project,
                                                    sessionID: session.id))
            let item = try XCTUnwrap(model.promoteNote(first.id, projectID: project))
            _ = model.addNote("Store it per project", author: .user, projectID: project, sessionID: nil)
            model.attachNote(model.notes(inProject: project)[0].id, to: item.id, projectID: project)
            model.openPlanItem(item.id, projectID: project)

            let draft = model.planSessionDraft(forItem: item, inProject: project)
            XCTAssertEqual(draft.name, "Shell panel height resets")
            XCTAssertNil(draft.folderID, "items have no folder: the session starts Unfiled until you pick one")
            XCTAssertEqual(draft.skills, [], "nothing matches yet")
            XCTAssertEqual(model.suggestedSkills(forItem: item, inProject: project, folderID: folder), ["shell-map"],
                           "meant for the folder picked for the session")
            XCTAssertEqual(draft.promptBody, "Shell panel height resets\n\nNotes:\n- Shell panel height resets\n- Store it per project")
            XCTAssertTrue(model.canStartSession(fromItem: item))
            return (model, project, folder, item.id, skillsRoot)
        }
        let sessionID = try await MainActor.run { () -> UUID in
            try XCTUnwrap(model.startSession(fromItem: itemID, projectID: project, name: "Panel height", folderID: folder,
                                             role: .code, skills: ["shell-map"], useWorktree: true))
        }
        await model.lastTask?.value
        try await MainActor.run {
            let item = try XCTUnwrap(model.item(itemID, inProject: project))
            XCTAssertEqual(item.status, .inSession)
            XCTAssertEqual(item.sessionID, sessionID)
            XCTAssertFalse(model.canStartSession(fromItem: item))
            let session = try XCTUnwrap(model.workspace.session(sessionID))
            XCTAssertEqual(model.session(workingOn: item)?.id, sessionID)
            XCTAssertEqual(session.namedSkills, ["shell-map"])
            XCTAssertTrue(session.hasAssistant, "launched with the flags")
            XCTAssertEqual(model.workspace.group(of: sessionID), .folder(folder))

            let dispatch = try XCTUnwrap(runner.commands.first { $0.contains("--bg") })
            XCTAssertTrue(dispatch.containsSequence(["--add-dir", skillsRoot.path]))
            let plugin = support.appendingPathComponent("plugin/claudio").path
            XCTAssertTrue(dispatch.containsSequence(["--plugin-dir", plugin]))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: plugin + "/bin/claudio"), "installed at launch")
            XCTAssertEqual(dispatch.last, """
                Shell panel height resets

                Notes:
                - Shell panel height resets
                - Store it per project

                Use these skills: /shell-map
                """)
            XCTAssertEqual(try FileAssistantAudit.lastAction(support, project), "itemChanged")
        }
    }

    func testSessionsWithoutFlagsAreNotMarked() async throws {
        let runner = FakeRunner()
        let (model, sessionID) = try await MainActor.run { () -> (AppModel, UUID) in
            let (model, project, _, _) = try makeFixture(runner: runner)
            let request = NewSessionRequest(projectID: project, folderID: nil, name: "x", role: .code, prompt: "Fix it",
                                            model: nil, permissionMode: .standard)
            return (model, try XCTUnwrap(model.createSession(request)))
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertFalse(runner.commands.first { $0.contains("--bg") }?.contains("--add-dir") ?? true,
                           "the memory store keeps nothing on disk, so there are no flags")
            XCTAssertFalse(model.workspace.session(sessionID)?.hasAssistant ?? true)
        }
    }
}

/// Reads the newest audit entry's action from a file store.
private enum FileAssistantAudit {
    static func lastAction(_ support: URL, _ project: UUID) throws -> String? {
        let url = support.appendingPathComponent("assistant/\(project.uuidString.lowercased())/audit.jsonl")
        let last = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").last.map(String.init) ?? ""
        return (try JSONDecoder().decode(JSONValue.self, from: Data(last.utf8)))["action"]?.stringValue
    }
}

extension AppModel {
    /// Links an item to a session as Start Session does, without a launch.
    func startSessionForTest(item itemID: UUID, session sessionID: UUID, projectID: UUID) {
        guard var item = item(itemID, inProject: projectID) else { return }
        let before = item
        item.status = .inSession
        item.sessionID = sessionID
        _ = change(projectID: projectID, recording: AuditEntry(at: now(), actor: .user, action: .itemChanged,
                                                               beforeItem: before, afterItem: item, cause: "ui")) { data in
            if let index = data.items.firstIndex(where: { $0.id == itemID }) { data.items[index] = item }
        }
    }
}

extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<($0 + sequence.count)]) == sequence }
    }
}
