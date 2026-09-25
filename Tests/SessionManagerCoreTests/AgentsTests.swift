import XCTest
@testable import SessionManagerCore

final class AgentListParserTests: XCTestCase {
    func testParsesBackgroundAgentsFromRealOutput() throws {
        let agents = try AgentListParser.parse(Data(Fixtures.string("agents.json").utf8))
        XCTAssertEqual(agents.map(\.id), ["83526b6d", "fb72709a", "922b2630", "0badc0de", "38530432"], "interactive sessions are skipped")

        let busy = agents[1]
        XCTAssertEqual(busy.sessionID, "fb72709a-291a-41a1-ab00-ed7fe2d9115b")
        XCTAssertEqual(busy.name, "websocket close state")
        XCTAssertEqual(busy.cwd, "/Users/tim/Documents/Code/DigiScript")
        XCTAssertEqual(busy.pid, 10771)
        XCTAssertTrue(busy.isAlive)
        XCTAssertEqual(busy.state, "working")
        XCTAssertEqual(busy.sessionStatus, .working)
        XCTAssertEqual(busy.startedAt, Date(timeIntervalSince1970: 1_790_275_729.280))

        XCTAssertFalse(agents[0].isAlive)
        XCTAssertEqual(agents[0].sessionStatus, .completed)
        XCTAssertEqual(agents[2].sessionStatus, .completed, "done, even though idle and alive")
        XCTAssertEqual(agents[3].sessionStatus, .awaitingInput)
        XCTAssertEqual(agents[3].waitingFor, "permission")
    }

    func testStatusMapping() {
        func agent(state: String?, status: String?) -> BackgroundAgent {
            BackgroundAgent(id: "x", sessionID: "x", cwd: "/", name: nil, pid: 1, status: status, state: state, waitingFor: nil, startedAt: nil)
        }
        XCTAssertEqual(agent(state: "working", status: "busy").sessionStatus, .working)
        XCTAssertEqual(agent(state: "blocked", status: nil).sessionStatus, .awaitingInput)
        XCTAssertEqual(agent(state: nil, status: "waiting").sessionStatus, .awaitingInput)
        XCTAssertEqual(agent(state: "review_ready", status: "idle").sessionStatus, .completed)
        XCTAssertEqual(agent(state: "failed", status: nil).sessionStatus, .completed)
        XCTAssertEqual(agent(state: nil, status: "busy").sessionStatus, .working)
    }

    func testInvalidOutputThrows() {
        XCTAssertThrowsError(try AgentListParser.parse(Data("oops".utf8)))
        XCTAssertEqual(try AgentListParser.parse(Data("[]".utf8)), [])
    }

    func testParsesDispatchOutput() {
        let output = """
        backgrounded · 38530432
          claude agents             list sessions
          claude attach 38530432    open in this terminal
        """
        XCTAssertEqual(AgentListParser.dispatchedID(from: output), "38530432")
        XCTAssertEqual(AgentListParser.dispatchedID(from: "\u{1B}[2mbackgrounded\u{1B}[0m · abcdef12\n"), "abcdef12")
        XCTAssertNil(AgentListParser.dispatchedID(from: "Workspace not trusted."))
    }
}

final class WorktreeTests: XCTestCase {
    func testSlugifiesSessionNames() {
        XCTAssertEqual(Worktree.name(for: "PR review inline #1427"), "pr-review-inline-1427")
        XCTAssertEqual(Worktree.name(for: "  Fix: storage/bug!! "), "fix-storage-bug")
        XCTAssertEqual(Worktree.name(for: "!!!"), "session")
        XCTAssertLessThanOrEqual(Worktree.name(for: String(repeating: "word ", count: 30)).count, 40)
        XCTAssertFalse(Worktree.name(for: String(repeating: "word ", count: 30)).hasSuffix("-"))
    }

    func testUniqueNamesAvoidExistingWorktrees() {
        XCTAssertEqual(Worktree.uniqueName(for: "probe", existing: []), "probe")
        XCTAssertEqual(Worktree.uniqueName(for: "probe", existing: ["probe", "probe-2"]), "probe-3")
    }

    func testRepositoryRootOfWorktreePath() {
        XCTAssertEqual(Worktree.repositoryRoot(of: "/Users/tim/Code/DigiScript/.claude/worktrees/collab-v3-phase1"), "/Users/tim/Code/DigiScript")
        XCTAssertEqual(Worktree.repositoryRoot(of: "/Users/tim/Code/DigiScript/.claude/worktrees/a/sub"), "/Users/tim/Code/DigiScript")
        XCTAssertNil(Worktree.repositoryRoot(of: "/Users/tim/Code/DigiScript"))
        XCTAssertEqual(Worktree.name(ofPath: "/Users/tim/Code/DigiScript/.claude/worktrees/collab-v3-phase1"), "collab-v3-phase1")
    }

    func testWorkspaceFindsProjectForWorktreeDirectories() {
        var ws = Workspace()
        let p = ws.addProject(path: "/Users/tim/Code/DigiScript")
        XCTAssertEqual(ws.projectID(forWorkingDirectory: "/Users/tim/Code/DigiScript"), p)
        XCTAssertEqual(ws.projectID(forWorkingDirectory: "/Users/tim/Code/DigiScript/.claude/worktrees/x"), p)
        XCTAssertNil(ws.projectID(forWorkingDirectory: "/Users/tim/Code/Other"))
    }

    func testDiscoveryIncludesWorktreeSessions() throws {
        let home = try makeTemporaryDirectory()
        let main = home.appendingPathComponent("projects/-code-app")
        let tree = home.appendingPathComponent("projects/-code-app--claude-worktrees-feature")
        let other = home.appendingPathComponent("projects/-code-app2")
        for (dir, cwd, id) in [(main, "/code/app", "a"), (tree, "/code/app/.claude/worktrees/feature", "b"), (other, "/code/app2", "c")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"type":"user","cwd":"\#(cwd)","timestamp":"2026-09-25T10:00:00Z","message":{"content":"hi"}}"#
                .write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        let found = try SessionDiscovery(claudeHome: home).discover(projectPath: "/code/app")
        XCTAssertEqual(Set(found.map(\.claudeSessionID)), ["a", "b"])
        XCTAssertEqual(found.first { $0.claudeSessionID == "b" }?.workingDirectory, "/code/app/.claude/worktrees/feature")

        let projects = try SessionDiscovery(claudeHome: home).discoverProjects(fileExists: { _ in true })
        XCTAssertEqual(Set(projects.map(\.path)), ["/code/app", "/code/app2"], "worktrees belong to their repository")
    }
}

final class AgentCommandTests: XCTestCase {
    let session = Session(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, projectID: UUID(), name: "storage fix",
                          workingDirectory: "/Users/tim/My Code/app", model: "claude-opus-5-5", permissionMode: .acceptEdits)

    private func context() -> AgentCommands {
        AgentCommands(claudeExecutable: "/Users/tim/.local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/tmp/events.log",
                      baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/tim"])
    }

    func testDispatchInWorktree() {
        let command = context().dispatch(session: session, prompt: "Fix it", worktree: "storage-fix")
        XCTAssertEqual(Array(command.claudeArguments.prefix(8)), [
            "Fix it", "--bg", "--worktree", "storage-fix", "--model", "claude-opus-5-5", "--permission-mode", "acceptEdits",
        ])
        XCTAssertEqual(command.claudeArguments[8], "--settings")
        XCTAssertTrue(command.arguments[2].hasPrefix("cd '/Users/tim/My Code/app' && exec '/Users/tim/.local/bin/claude' 'Fix it' '--bg' "))
        XCTAssertEqual(command.executable, "/bin/zsh")
    }

    func testDispatchWithoutWorktree() {
        let command = context().dispatch(session: session, prompt: "Fix it", worktree: nil)
        XCTAssertFalse(command.claudeArguments.contains("--worktree"))
    }

    func testResumeInBackground() {
        var s = session
        s.claudeSessionID = "fb72709a-291a-41a1-ab00-ed7fe2d9115b"
        s.workingDirectory = "/code/app/.claude/worktrees/x"
        let command = context().resume(session: s)
        XCTAssertEqual(Array(command.claudeArguments.prefix(3)), ["--bg", "--resume", "fb72709a-291a-41a1-ab00-ed7fe2d9115b"])
        XCTAssertTrue(command.arguments[2].hasPrefix("cd '/code/app/.claude/worktrees/x' && "))
    }

    func testResumeInBackgroundWithAMessage() {
        var s = session
        s.claudeSessionID = "fb72709a-291a-41a1-ab00-ed7fe2d9115b"
        let command = context().resume(session: s, prompt: "  Carry on with the tests  ")
        XCTAssertEqual(Array(command.claudeArguments.prefix(4)), ["Carry on with the tests", "--bg", "--resume", "fb72709a-291a-41a1-ab00-ed7fe2d9115b"])
        XCTAssertEqual(context().resume(session: s, prompt: "   ").claudeArguments.first, "--bg", "a blank message is just a resume")
    }

    func testAttachStopRemoveAndList() {
        let c = context()
        XCTAssertEqual(c.attach(agentID: "fb72709a", workingDirectory: "/code").claudeArguments, ["attach", "fb72709a"])
        XCTAssertEqual(c.attach(agentID: "fb72709a", workingDirectory: "/code").environment["TERM"], "xterm-256color")
        XCTAssertEqual(c.stop(agentID: "fb72709a").claudeArguments, ["stop", "fb72709a"])
        XCTAssertEqual(c.remove(agentID: "fb72709a").claudeArguments, ["rm", "fb72709a"])
        XCTAssertEqual(c.list().claudeArguments, ["agents", "--json", "--all"])
    }
}

final class ProcessCommandRunnerTests: XCTestCase {
    func testRunsThroughTheShellAndCapturesOutput() async throws {
        let dir = try makeTemporaryDirectory()
        let fake = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho \"backgrounded · 1234abcd\"\necho \"args: $*\" >&2\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let commands = AgentCommands(claudeExecutable: fake.path, shell: "/bin/sh", hookEventsPath: "/tmp/x", loginShell: false)
        let result = await ProcessCommandRunner().run(commands.stop(agentID: "1234abcd"))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(AgentListParser.dispatchedID(from: result.output), "1234abcd")
        XCTAssertTrue(result.errorOutput.contains("args: stop 1234abcd"))
    }

    func testReportsFailures() async {
        let commands = AgentCommands(claudeExecutable: "/nonexistent/claude", shell: "/bin/sh", hookEventsPath: "/tmp/x", loginShell: false)
        let result = await ProcessCommandRunner().run(commands.list())
        XCTAssertNotEqual(result.exitCode, 0)
    }
}

final class InteractiveSessionParserTests: XCTestCase {
    func testParsesInteractiveTerminalSessions() throws {
        let data = Data(try Fixtures.string("agents-interactive.json").utf8)
        let sessions = try AgentListParser.parseInteractive(data)
        XCTAssertEqual(sessions, [InteractiveSession(sessionID: "312fdcb6-6989-492e-a86f-3afc149f9c90", pid: 64054,
                                                     cwd: "/Users/tim/Documents/Code/DigiScript", status: "busy")])
        XCTAssertEqual(sessions[0].isBusy, true)
        XCTAssertEqual(try AgentListParser.parse(data).map(\.id), ["2bd6a047"], "background parsing unaffected")
    }

    func testParsesCopyNoteFromResume() {
        let output = """
        note: started a copy of that conversation as 2bd6a047. To continue a session under its own id, pass its full session id (lowercase, as `claude agents --json` prints it) to --resume.
        backgrounded · 2bd6a047
        """
        XCTAssertEqual(AgentListParser.copiedID(from: output), "2bd6a047")
        XCTAssertEqual(AgentListParser.dispatchedID(from: output), "2bd6a047")
        XCTAssertNil(AgentListParser.copiedID(from: "backgrounded · 2bd6a047\n"))
    }
}
