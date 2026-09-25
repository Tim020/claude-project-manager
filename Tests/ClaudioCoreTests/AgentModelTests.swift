import XCTest
@testable import ClaudioCore

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    var agentsJSON = "[]"
    var dispatchOutput = "backgrounded · abcd1234\n  claude attach abcd1234    open in this terminal\n"
    var dispatchExit: Int32 = 0
    var usageOutput = "Total cost: $0.0000\n"
    var versionOutput = "2.1.283 (Claude Code)\n"
    var versionExit: Int32 = 0
    var versionError = ""
    var authOutput = #"{"loggedIn": true, "authMethod": "claude.ai", "email": "tim@example.com", "subscriptionType": "pro"}"#
    var agentsExit: Int32 = 0
    var agentsError = ""

    var commands: [[String]] { lock.withLock { _commands } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        lock.withLock { _commands.append(command.claudeArguments) }
        let args = command.claudeArguments
        if args.first == "agents" {
            return CommandResult(exitCode: agentsExit, output: agentsExit == 0 ? agentsJSON : "", errorOutput: agentsError)
        }
        if args == ["--version"] { return CommandResult(exitCode: versionExit, output: versionOutput, errorOutput: versionError) }
        if args == ["auth", "status"] { return CommandResult(exitCode: 0, output: authOutput, errorOutput: "") }
        if args.contains("/usage") { return CommandResult(exitCode: 0, output: usageOutput, errorOutput: "") }
        if args.contains("--bg") { return CommandResult(exitCode: dispatchExit, output: dispatchExit == 0 ? dispatchOutput : "", errorOutput: dispatchExit == 0 ? "" : "Workspace not trusted.") }
        return CommandResult(exitCode: 0, output: "", errorOutput: "")
    }
}

/// Test bodies hop to the main actor explicitly: a `@MainActor` test class
/// breaks test discovery on Linux.
final class AgentModelTests: XCTestCase {
    let repo = "/Users/tim/Documents/Code/DigiScript"
    var store = MemoryStore()
    var runner = FakeRunner()
    var terminals: FakeTerminals!
    var gitRepos: Set<String> = ["/Users/tim/Documents/Code/DigiScript"]

    @MainActor
    private func makeModel() throws -> AppModel {
        let model = AppModel(
            store: store,
            discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
            hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("hooks.log"),
            runner: runner,
            locateClaude: { _ in "/usr/local/bin/claude" },
            isGitRepository: { [unowned self] in self.gitRepos.contains($0) },
            shell: "/bin/zsh",
            now: { Date(timeIntervalSince1970: 1_790_340_000) },
            home: "/Users/tim")
        terminals = FakeTerminals()
        model.terminals = terminals
        return model
    }

    @MainActor
    private func request(_ project: UUID, name: String = "storage fix", prompt: String = "Fix it", worktree: Bool = true) -> NewSessionRequest {
        var r = NewSessionRequest(projectID: project, folderID: nil, name: name, role: .code, prompt: prompt, model: nil, permissionMode: .standard)
        r.useWorktree = worktree
        return r
    }

    func testNewSessionDispatchesBackgroundAgentInWorktreeThenAttaches() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            let id = try XCTUnwrap(model.createSession(request(p)))
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
            return (model, id)
        }
        await model.lastTask?.value
        try await MainActor.run {
            let dispatch = try XCTUnwrap(runner.commands.first { $0.contains("--bg") })
            XCTAssertEqual(Array(dispatch.prefix(4)), ["Fix it", "--bg", "--worktree", "storage-fix"])
            XCTAssertEqual(model.workspace.session(id)?.agentID, "abcd1234")
            XCTAssertTrue(model.workspace.session(id)!.hasConversation)
            XCTAssertTrue(model.isRunning(id), "attached")
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments, ["attach", "abcd1234"])
        }
    }

    func testNoWorktreeOutsideGitRepositoriesOrWhenUnchecked() async throws {
        gitRepos = []
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            model.createSession(request(p))
            return model
        }
        await model.lastTask?.value
        XCTAssertFalse(runner.commands.first { $0.contains("--bg") }!.contains("--worktree"))
    }

    func testDispatchFailureReportsError() async throws {
        runner.dispatchExit = 1
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            return (model, try XCTUnwrap(model.createSession(request(p))))
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(model.errorMessage, "Couldn't start the agent: Workspace not trusted.")
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertFalse(model.isRunning(id))
        }
    }

    func testRefreshAgentsImportsLinksAndUpdatesSessions() async throws {
        runner.agentsJSON = try Fixtures.string("agents.json")
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            model.addProject(path: repo)
            return model
        }
        await model.refreshAgents()
        try await MainActor.run {
            let names = Set(model.workspace.sessions.map(\.name))
            XCTAssertEqual(names, ["pdf script handling", "websocket close state", "collaborative script editing", "needs approval"],
                           "agents in other projects are ignored")
            let collab = try XCTUnwrap(model.workspace.sessions.first { $0.agentID == "922b2630" })
            XCTAssertEqual(collab.workingDirectory, "/Users/tim/Documents/Code/DigiScript/.claude/worktrees/collab-v3-phase1")
            XCTAssertEqual(collab.claudeSessionID, "922b2630-bcc9-4e24-961b-f8ab26f91379")
            XCTAssertTrue(model.isAgentAlive(collab.id))
            let busy = try XCTUnwrap(model.workspace.sessions.first { $0.agentID == "fb72709a" })
            XCTAssertEqual(busy.status, .working)
            let blocked = try XCTUnwrap(model.workspace.sessions.first { $0.agentID == "0badc0de" })
            XCTAssertEqual(blocked.status, .awaitingInput)
            let done = try XCTUnwrap(model.workspace.sessions.first { $0.agentID == "83526b6d" })
            XCTAssertFalse(model.isAgentAlive(done.id))
            XCTAssertTrue(model.workspace.openSessionIDs.isEmpty, "imported agents start with closed tabs")
        }
    }

    func testAgentNameReplacesAutomaticNameButNotCustomOnes() async throws {
        let (model, auto, custom) = try await MainActor.run { () -> (AppModel, UUID, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            let auto = try XCTUnwrap(model.createSession(request(p, name: "")))
            let custom = try XCTUnwrap(model.createSession(request(p, name: "my name")))
            return (model, auto, custom)
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(model.workspace.session(auto)?.name, "Fix it")
        }
        runner.agentsJSON = #"[{"id":"abcd1234","sessionId":"abcd1234-0000","kind":"background","cwd":"\#(repo)/.claude/worktrees/fix-it","name":"storage fix agent","pid":5,"status":"idle","state":"done"}]"#
        await model.refreshAgents()
        await MainActor.run {
            // Both dispatches reported the same fake id; the first session claimed it.
            XCTAssertEqual(model.workspace.session(auto)?.name, "storage fix agent")
            XCTAssertEqual(model.workspace.session(custom)?.name, "my name")
            XCTAssertEqual(model.workspace.session(auto)?.status, .completed)
        }
    }

    func testAgentStateOnlyOverridesWhenItChanges() async throws {
        runner.agentsJSON = #"[{"id":"fb72709a","sessionId":"fb72709a-1","kind":"background","cwd":"\#(repo)","name":"n","pid":5,"status":"busy","state":"working"}]"#
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            model.addProject(path: repo)
            return model
        }
        await model.refreshAgents()
        let id = await MainActor.run { model.workspace.sessions[0].id }
        // A hook (e.g. a permission prompt) updates the status between polls…
        await MainActor.run { model.applyStatus(id, .awaitingInput) }
        await model.refreshAgents()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.status, .awaitingInput, "unchanged agent state doesn't clobber it") }
    }

    func testClosingAgentTabDetachesButKeepsAgent() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            return (model, try XCTUnwrap(model.createSession(request(p))))
        }
        await model.lastTask?.value
        await MainActor.run {
            model.closeTab(id)
            XCTAssertEqual(terminals.terminated, [id], "the attach terminal is closed")
            XCTAssertFalse(model.isRunning(id))
            XCTAssertEqual(model.workspace.session(id)?.agentID, "abcd1234")
        }
        XCTAssertFalse(runner.commands.contains { $0.first == "stop" })
    }

    func testOpeningDetachedAliveAgentReattaches() async throws {
        runner.agentsJSON = #"[{"id":"fb72709a","sessionId":"fb72709a-1","kind":"background","cwd":"\#(repo)","name":"n","pid":5,"status":"busy","state":"working"}]"#
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            model.addProject(path: repo)
            return model
        }
        await model.refreshAgents()
        await MainActor.run {
            let id = model.workspace.sessions[0].id
            model.resume(id)
            XCTAssertTrue(model.isRunning(id))
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments, ["attach", "fb72709a"])
        }
    }

    func testResumingStoppedAgentUsesBackgroundResume() async throws {
        runner.agentsJSON = #"[{"id":"83526b6d","sessionId":"83526b6d-2eed","kind":"background","cwd":"\#(repo)","name":"n","state":"done"}]"#
        runner.dispatchOutput = "backgrounded · 83526b6d\n"
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            model.addProject(path: repo)
            return model
        }
        await model.refreshAgents()
        let id = await MainActor.run { () -> UUID in
            let id = model.workspace.sessions[0].id
            model.resume(id)
            return id
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(Array(runner.commands.last { $0.contains("--bg") }!.prefix(3)), ["--bg", "--resume", "83526b6d-2eed"])
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments, ["attach", "83526b6d"])
        }
    }

    func testStopAndDeleteUseTheCLI() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            return (model, try XCTUnwrap(model.createSession(request(p))))
        }
        await model.lastTask?.value
        await MainActor.run { model.stop(id) }
        await model.lastTask?.value
        XCTAssertTrue(runner.commands.contains(["stop", "abcd1234"]))
        await MainActor.run { model.deleteSession(id) }
        await model.lastTask?.value
        XCTAssertTrue(runner.commands.contains(["rm", "abcd1234"]))
    }

    func testShutdownDetachesWithoutStoppingAgents() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            return (model, try XCTUnwrap(model.createSession(request(p))))
        }
        await model.lastTask?.value
        await MainActor.run {
            model.shutdown()
            XCTAssertEqual(terminals.terminated, [id])
        }
        XCTAssertFalse(runner.commands.contains { $0.first == "stop" })
    }

    func testDirectModeWhenBackgroundAgentsAreOff() async throws {
        try await MainActor.run {
            let model = try makeModel()
            var settings = model.settings
            settings.useBackgroundAgents = false
            model.updateSettings(settings)
            let p = model.addProject(path: repo)
            let id = try XCTUnwrap(model.createSession(request(p)))
            XCTAssertNil(model.lastTask)
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments.first, "Fix it")
        }
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testAgentAttachExitMarksDetachedNotCompleted() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            return (model, try XCTUnwrap(model.createSession(request(p))))
        }
        await model.lastTask?.value
        await MainActor.run {
            model.terminalExited(id, exitCode: 0)
            XCTAssertFalse(model.isRunning(id))
            XCTAssertEqual(model.workspace.session(id)?.status, .working, "the agent's own state decides, not the attach process")
        }
    }

    // MARK: Sessions open in a terminal

    private func interactiveJSON(_ sessionID: String, status: String) -> String {
        #"[{"pid":64054,"cwd":"\#(repo)","kind":"interactive","startedAt":1790343098828,"sessionId":"\#(sessionID)","name":"x-57","status":"\#(status)"}]"#
    }

    @MainActor
    private func modelWithImportedSession(claudeSessionID: String) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo)
        let f = try state.workspace.createFolder(in: p, named: "Storage fix")
        try state.workspace.addSession(Session(projectID: p, claudeSessionID: claudeSessionID, hasConversation: true,
                                               name: "investigate issue correlation", workingDirectory: repo), toFolder: f)
        store.state = state
        let model = try makeModel()
        return (model, model.workspace.sessions[0].id)
    }

    func testTerminalSessionsGetLiveStatus() async throws {
        let sid = "312fdcb6-6989-492e-a86f-3afc149f9c90"
        let (model, id) = try await MainActor.run { try modelWithImportedSession(claudeSessionID: sid) }
        runner.agentsJSON = interactiveJSON(sid, status: "busy")
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertTrue(model.isOpenInTerminal(id))
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
        }
        runner.agentsJSON = interactiveJSON(sid, status: "idle")
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertTrue(model.isOpenInTerminal(id))
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
        }
        runner.agentsJSON = "[]"
        await model.refreshAgents()
        await MainActor.run { XCTAssertFalse(model.isOpenInTerminal(id), "terminal closed") }
    }

    func testIdleTerminalSessionKeepsAwaitingInput() async throws {
        let sid = "312fdcb6-6989-492e-a86f-3afc149f9c90"
        let (model, id) = try await MainActor.run { try modelWithImportedSession(claudeSessionID: sid) }
        await MainActor.run { model.applyStatus(id, .awaitingInput) }
        runner.agentsJSON = interactiveJSON(sid, status: "idle")
        await model.refreshAgents()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.status, .awaitingInput) }
    }

    func testResumingATerminalSessionAsksFirstThenStartsALabelledCopy() async throws {
        let sid = "312fdcb6-6989-492e-a86f-3afc149f9c90"
        let (model, original) = try await MainActor.run { try modelWithImportedSession(claudeSessionID: sid) }
        runner.agentsJSON = interactiveJSON(sid, status: "idle")
        await model.refreshAgents()
        await MainActor.run {
            model.resume(original)
            XCTAssertEqual(model.copyConfirmation, original, "asks before copying a session open elsewhere")
            XCTAssertNil(model.lastTask)
        }
        runner.dispatchOutput = "note: started a copy of that conversation as 2bd6a047. To continue…\nbackgrounded · 2bd6a047\n"
        await MainActor.run { model.resumeCopy(of: original) }
        await model.lastTask?.value
        try await MainActor.run {
            XCTAssertNil(model.copyConfirmation)
            XCTAssertEqual(Array(runner.commands.last { $0.contains("--bg") }!.prefix(3)), ["--bg", "--resume", sid])
            let copy = try XCTUnwrap(model.workspace.sessions.first { $0.id != original })
            XCTAssertEqual(copy.name, "investigate issue correlation (copy)")
            XCTAssertEqual(copy.agentID, "2bd6a047")
            XCTAssertEqual(model.workspace.group(of: copy.id), model.workspace.group(of: original), "sits beside the original")
            XCTAssertEqual(model.selectedSessionID, copy.id)
            XCTAssertEqual(model.takePendingLaunch(copy.id)?.claudeArguments, ["attach", "2bd6a047"])
            XCTAssertEqual(model.workspace.session(original)?.claudeSessionID, sid, "original untouched")
            XCTAssertNil(model.workspace.session(original)?.agentID)
        }
    }

    func testUnexpectedCopyOnResumeAlsoBecomesASeparateSession() async throws {
        // Resuming a stopped session normally continues it; if the CLI copies it
        // anyway (e.g. it's still open somewhere we couldn't see), don't relink.
        let sid = "83526b6d-2eed-464a-b7ae-5f52c45500d0"
        let (model, original) = try await MainActor.run { try modelWithImportedSession(claudeSessionID: sid) }
        runner.dispatchOutput = "note: started a copy of that conversation as 99990000.\nbackgrounded · 99990000\n"
        await MainActor.run { model.resume(original) }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(model.workspace.sessions.count, 2)
            XCTAssertNil(model.workspace.session(original)?.agentID)
            XCTAssertEqual(model.workspace.sessions.first { $0.id != original }?.agentID, "99990000")
        }
    }

    func testReturnToSessionQueuesAFreshAttach() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            return (model, try XCTUnwrap(model.createSession(request(p))))
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertNotNil(model.takePendingLaunch(id))
            XCTAssertTrue(model.returnToSession(id))
            XCTAssertTrue(model.isRunning(id))
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments, ["attach", "abcd1234"])
            XCTAssertTrue(model.log.entries.contains { $0.title.hasPrefix("Returned to") })
        }
    }

    func testReturnToSessionNeedsAnAgent() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            var settings = model.settings
            settings.useBackgroundAgents = false
            model.updateSettings(settings)
            let p = model.addProject(path: repo)
            let id = try XCTUnwrap(model.createSession(request(p)))
            XCTAssertFalse(model.returnToSession(id))
        }
    }

    // MARK: Resuming with a message

    func testResumeWithMessageSendsItAsTheFirstPrompt() async throws {
        runner.agentsJSON = #"[{"id":"83526b6d","sessionId":"83526b6d-2eed","kind":"background","cwd":"\#(repo)","name":"n","state":"done"}]"#
        runner.dispatchOutput = "backgrounded · 83526b6d\n"
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            model.addProject(path: repo)
            return model
        }
        await model.refreshAgents()
        let id = await MainActor.run { () -> UUID in
            let id = model.workspace.sessions[0].id
            model.resume(id, message: "Carry on")
            XCTAssertEqual(model.workspace.session(id)?.status, .working, "shows Working straight away")
            return id
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(Array(runner.commands.last { $0.contains("--bg") }!.prefix(4)), ["Carry on", "--bg", "--resume", "83526b6d-2eed"])
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments, ["attach", "83526b6d"])
        }
    }

    func testResumeWithMessageInDirectMode() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            state.settings.useBackgroundAgents = false
            let p = state.workspace.addProject(path: repo)
            try state.workspace.addSession(Session(projectID: p, claudeSessionID: "abc", hasConversation: true, name: "s", workingDirectory: repo))
            store.state = state
            let model = try makeModel()
            let id = model.workspace.sessions[0].id
            model.resume(id, message: "Carry on")
            XCTAssertEqual(Array(model.takePendingLaunch(id)!.claudeArguments.prefix(3)), ["Carry on", "--resume", "abc"])
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
        }
    }

    func testCopyConfirmationKeepsTheMessage() async throws {
        let sid = "312fdcb6-6989-492e-a86f-3afc149f9c90"
        let (model, original) = try await MainActor.run { try modelWithImportedSession(claudeSessionID: sid) }
        runner.agentsJSON = interactiveJSON(sid, status: "idle")
        await model.refreshAgents()
        await MainActor.run { model.resume(original, message: "Try again") }
        runner.dispatchOutput = "note: started a copy of that conversation as 2bd6a047.\nbackgrounded · 2bd6a047\n"
        await MainActor.run { model.resumeCopy(of: original) }
        await model.lastTask?.value
        XCTAssertEqual(runner.commands.last { $0.contains("--bg") }?.first, "Try again")
    }
}
