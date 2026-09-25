import XCTest
@testable import SessionManagerCore

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    var agentsJSON = "[]"
    var dispatchOutput = "backgrounded · abcd1234\n  claude attach abcd1234    open in this terminal\n"
    var dispatchExit: Int32 = 0

    var commands: [[String]] { lock.withLock { _commands } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        lock.withLock { _commands.append(command.claudeArguments) }
        let args = command.claudeArguments
        if args.first == "agents" { return CommandResult(exitCode: 0, output: agentsJSON, errorOutput: "") }
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
}
