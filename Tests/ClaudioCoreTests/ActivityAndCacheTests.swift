import XCTest
@testable import ClaudioCore

final class SessionSummaryCacheTests: XCTestCase {
    private func writeSession(_ dir: URL, _ id: String, prompt: String) throws {
        try #"{"type":"user","cwd":"/code/app","timestamp":"2026-09-25T10:00:00Z","message":{"content":"\#(prompt)"}}"#
            .write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    func testUnchangedFilesAreNotReparsed() throws {
        let home = try makeTemporaryDirectory()
        let dir = home.appendingPathComponent("projects/-code-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSession(dir, "a", prompt: "first")
        try writeSession(dir, "b", prompt: "second")
        let discovery = SessionDiscovery(claudeHome: home)
        let cache = SessionSummaryCache()

        XCTAssertEqual(try discovery.discover(projectPath: "/code/app", cache: cache).count, 2)
        XCTAssertEqual(cache.parses, 2)
        XCTAssertEqual(try discovery.discover(projectPath: "/code/app", cache: cache).count, 2)
        XCTAssertEqual(cache.parses, 2, "second scan uses the cache")

        try writeSession(dir, "b", prompt: "second, but longer now")
        let found = try discovery.discover(projectPath: "/code/app", cache: cache)
        XCTAssertEqual(cache.parses, 3, "only the changed file is re-read")
        XCTAssertEqual(found.first { $0.claudeSessionID == "b" }?.firstPrompt, "second, but longer now")
    }
}

final class CommandDisplayTests: XCTestCase {
    func testDisplayCommandAbbreviatesHookSettings() {
        let commands = AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/tmp/h.log",
                                     baseEnvironment: ["HOME": "/Users/tim"])
        let session = Session(projectID: UUID(), name: "s", workingDirectory: "/code/app")
        let display = commands.dispatch(session: session, prompt: "Fix it", worktree: "fix-it").displayCommand
        XCTAssertEqual(display, "claude 'Fix it' --bg --worktree fix-it --settings <hooks>")
        XCTAssertEqual(commands.list().displayCommand, "claude agents --json --all")
    }

    func testPollingAndQuickCommandsSkipTheLoginShell() {
        let commands = AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/tmp/h.log")
        XCTAssertEqual(commands.list().arguments.first, "-c", "polling every few seconds must not source shell profiles")
        XCTAssertEqual(commands.stop(agentID: "a").arguments.first, "-c")
        XCTAssertEqual(commands.attach(agentID: "a", workingDirectory: "/").arguments.first, "-l")
    }
}

final class ActivityLogTests: XCTestCase {
    func testEntriesAreCappedAndWrittenToFile() throws {
        let file = try makeTemporaryDirectory().appendingPathComponent("logs/app.log")
        let log = ActivityLog(fileURL: file, limit: 3)
        for i in 0..<5 { log.append(.info, "entry \(i)", date: Date(timeIntervalSince1970: 0)) }
        XCTAssertEqual(log.entries.map(\.title), ["entry 2", "entry 3", "entry 4"])
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("entry 0"), "the file keeps everything")
        XCTAssertTrue(text.contains("[info] entry 4"))
    }

    func testExportText() {
        let log = ActivityLog(fileURL: nil)
        log.append(.command, "claude agents --json --all", detail: "exit 0 · 120 ms", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(log.exportText.contains("[command] claude agents --json --all\n    exit 0 · 120 ms"))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }
}

/// Test bodies hop to the main actor explicitly: a `@MainActor` test class
/// breaks test discovery on Linux.
final class AppModelActivityTests: XCTestCase {
    let repo = "/Users/tim/Documents/Code/DigiScript"
    var store = MemoryStore()
    var runner = FakeRunner()

    @MainActor
    private func makeModel(claudeHome: URL? = nil) throws -> AppModel {
        let model = AppModel(
            store: store,
            discovery: SessionDiscovery(claudeHome: try claudeHome ?? makeTemporaryDirectory()),
            hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("hooks.log"),
            runner: runner,
            locateClaude: { _ in "/usr/local/bin/claude" },
            isGitRepository: { _ in true },
            shell: "/bin/zsh",
            now: { Date(timeIntervalSince1970: 1_790_340_000) },
            home: "/Users/tim")
        model.terminals = FakeTerminals()
        return model
    }

    func testCommandsTerminalsAndErrorsAreLogged() async throws {
        runner.dispatchExit = 1
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            let p = model.addProject(path: repo)
            var request = NewSessionRequest(projectID: p, folderID: nil, name: "fix", role: .code, prompt: "Fix it", model: nil, permissionMode: .standard)
            request.useWorktree = false
            model.createSession(request)
            return model
        }
        await model.lastTask?.value
        await MainActor.run {
            let entries = model.log.entries
            let dispatch = entries.first { $0.kind == .command && $0.title.hasPrefix("claude 'Fix it' --bg") }
            XCTAssertNotNil(dispatch)
            XCTAssertTrue(dispatch?.detail?.contains("exit 1") == true)
            XCTAssertTrue(dispatch?.detail?.contains("Workspace not trusted.") == true)
            XCTAssertTrue(entries.contains { $0.kind == .error && $0.title.contains("Couldn't start the agent") })
        }
    }

    func testTerminalLaunchAndExitAreLogged() async throws {
        try await MainActor.run {
            let model = try makeModel()
            var settings = model.settings
            settings.useBackgroundAgents = false
            model.updateSettings(settings)
            let p = model.addProject(path: repo)
            let id = try XCTUnwrap(model.createSession(NewSessionRequest(projectID: p, folderID: nil, name: "x", role: .code,
                                                                          prompt: "hi", model: nil, permissionMode: .standard)))
            _ = model.takePendingLaunch(id)
            model.terminalExited(id, exitCode: 2)
            XCTAssertTrue(model.log.entries.contains { $0.kind == .terminal && $0.title.hasPrefix("Terminal started: claude hi --session-id") })
            XCTAssertTrue(model.log.entries.contains { $0.kind == .terminal && $0.title == "Terminal exited (code 2): x" })
        }
    }

    func testAgentPollingIsOnlyLoggedWhenItChangesOrFails() async throws {
        let model = try await MainActor.run { try makeModel() }
        await model.refreshAgents()
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertEqual(model.log.entries.filter { $0.title == "claude agents --json --all" }.count, 1)
        }
        runner.agentsJSON = #"[{"id":"a1","sessionId":"a1-x","kind":"background","cwd":"/x","state":"done"}]"#
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertEqual(model.log.entries.filter { $0.title == "claude agents --json --all" }.count, 2)
        }
    }

    func testHistoryLoadsAsynchronously() async throws {
        let home = try Fixtures.url("claude-home")
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel(claudeHome: home)
            let p = model.addProject(path: repo)
            let s = model.workspace.sessions(in: .unfiled(projectID: p))[0]
            XCTAssertEqual(model.history(for: s.id), [], "not loaded yet")
            return (model, s.id)
        }
        await model.loadHistory(id)
        await MainActor.run {
            XCTAssertEqual(model.history(for: id).map(\.kind), [.prompt, .tool, .assistant])
        }
    }

    func testRefreshAllReadsDiskOffTheMainActorAndMergesResults() async throws {
        let home = try makeTemporaryDirectory()
        let dir = home.appendingPathComponent("projects/-code-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel(claudeHome: home)
            model.addProject(path: "/code/app")
            return model
        }
        try #"{"type":"user","cwd":"/code/app","timestamp":"2026-09-25T10:00:00Z","message":{"content":"new one"}}"#
            .write(to: dir.appendingPathComponent("n.jsonl"), atomically: true, encoding: .utf8)
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.sessions.map(\.name), ["new one"]) }
    }
}
