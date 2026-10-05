import XCTest
@testable import ClaudioCore

/// `/clear` starts a new conversation in the same process: the tab follows
/// it, and the one it left isn't imported as a session of its own. And a
/// stopped agent's tab doesn't attach to it again while it stops.
final class ClearAndStopTests: XCTestCase {
    let repo = "/code/proj"
    let worktree = "/code/proj/.claude/worktrees/docs-assistant-backend"
    let appID = UUID(uuidString: "D2135F55-2ABA-41C4-813D-26E0A5C6CFDE")!
    let before = "7d1da24e-122c-4b28-9495-195c4593ed3e"
    let after = "9e454d54-cc5e-4813-8660-75e62c026c53"
    var runner = FakeRunner()
    var store = MemoryStore()
    var terminals: FakeTerminals!
    var home: URL!
    var hooks: URL!

    /// A background agent's session, with both conversations' history in the
    /// worktree's folder, as Claude Code leaves them after `/clear`.
    @MainActor
    private func makeModel(workingDirectory: String? = nil) throws -> AppModel {
        home = try makeTemporaryDirectory()
        hooks = try makeTemporaryDirectory().appendingPathComponent("hooks.log")
        try Data().write(to: hooks)
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo)
        var session = Session(id: appID, projectID: p, claudeSessionID: before, hasConversation: true,
                              name: "Personal Assistant Implementation", workingDirectory: workingDirectory ?? worktree,
                              status: .awaitingInput)
        session.agentID = "7d1da24e"
        try state.workspace.addSession(session)
        store.state = state
        try writeHistory(before, cwd: repo, text: "Before the clear")
        try writeHistory(after, cwd: worktree, text: "After the clear")
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: home), hookEventsURL: hooks, runner: runner,
                             locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/zsh", home: "/home/u")
        terminals = FakeTerminals()
        model.terminals = terminals
        return model
    }

    /// The conversation began in the repository and moved into a worktree,
    /// so its history is in the worktree's folder but its first `cwd` is the
    /// repository (as in the real file).
    private func historyFile(_ id: String) -> URL {
        home.appendingPathComponent("projects")
            .appendingPathComponent(SessionDiscovery.directoryName(forProjectPath: worktree))
            .appendingPathComponent("\(id).jsonl")
    }

    private func writeHistory(_ id: String, cwd: String, text: String) throws {
        let file = historyFile(id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"\#(cwd)","message":{"content":"\#(text)"},"timestamp":"2026-09-29T16:35:00Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]},"timestamp":"2026-09-29T16:36:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func agentJSON(sessionID: String, alive: Bool = true) -> String {
        let process = alive ? #""pid":65709,"status":"idle","state":"done""# : #""state":"stopped""#
        return #"[{"id":"7d1da24e","cwd":"\#(worktree)","kind":"background","sessionId":"\#(sessionID)","name":"n",\#(process)}]"#
    }

    @MainActor
    private func clearFromHooks(_ model: AppModel) throws {
        try Data((try Fixtures.string("hook-clear.log")).utf8).write(to: hooks)
        model.pollHookEvents()
    }

    func testClearMovesTheTabToTheNewConversation() async throws {
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            try clearFromHooks(model)
            let session = try XCTUnwrap(model.workspace.session(appID))
            XCTAssertEqual(session.claudeSessionID, after)
            XCTAssertEqual(session.replacedConversations, [before])
            XCTAssertEqual(store.state.workspace.session(appID)?.replacedConversations, [before], "saved")
            return model
        }
        await model.refreshAll()
        await MainActor.run {
            XCTAssertEqual(model.workspace.sessions.map(\.id), [appID], "the old conversation isn't imported")
        }
    }

    /// A `/clear` while Claudio was closed: only the agent list says so.
    func testClearSeenOnlyInTheAgentList() async throws {
        runner.agentsJSON = agentJSON(sessionID: after)
        let model = try await MainActor.run { try makeModel() }
        await model.refreshAgents()
        await model.refreshAll()
        await MainActor.run {
            XCTAssertEqual(model.workspace.session(appID)?.claudeSessionID, after)
            XCTAssertEqual(model.workspace.session(appID)?.replacedConversations, [before])
            XCTAssertEqual(model.workspace.sessions.map(\.id), [appID])
        }
    }

    func testRemovedSessionsConversationsStayAway() async throws {
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            try clearFromHooks(model)
            model.deleteSession(appID, .claudioOnly)
            return model
        }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.sessions, []) }
    }

    func testDeletingEverywhereRemovesTheReplacedHistoryToo() async throws {
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel()
            try clearFromHooks(model)
            model.deleteSession(appID, .everywhere)
            return model
        }
        await model.lastTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile(before).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile(after).path))
        await model.refreshAll()
        await MainActor.run {
            XCTAssertEqual(model.workspace.sessions, [])
            XCTAssertTrue(model.workspace.deletedClaudeSessionIDs.isSuperset(of: [before, after]))
        }
    }

    func testOlderStateWithoutReplacedConversationsDecodes() throws {
        let session = Session(projectID: UUID(), claudeSessionID: before, name: "s", workingDirectory: repo)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json["replacedConversations"] = nil
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.replacedConversations, [])
    }

    /// Its working directory names the repository (a stopped agent is listed
    /// there), but the history is in the worktree's folder.
    func testTranscriptIsFoundInAWorktreesFolder() async throws {
        let model = try await MainActor.run { try makeModel(workingDirectory: repo) }
        await model.loadHistory(appID)
        await MainActor.run {
            XCTAssertFalse(model.history(for: appID).isEmpty, "found in the worktree's folder")
        }
    }

    /// Stop closes the terminal before the agent has gone. The tab, now
    /// without a terminal and its agent still listed alive, mustn't attach
    /// again (which brought the agent back).
    func testATabDoesntReattachWhileItsAgentStops() async throws {
        runner.agentsJSON = agentJSON(sessionID: before)
        let model = try await MainActor.run { try makeModel() }
        await model.refreshAgents()
        await MainActor.run {
            model.resume(appID)
            XCTAssertNotNil(model.takePendingLaunch(appID))
            // `claude stop` hasn't finished: the list still has it alive.
            model.stop(appID)
            XCTAssertTrue(model.isStopping(appID))
            model.attachIfLive(appID)
            XCTAssertFalse(model.isRunning(appID))
            XCTAssertNil(model.takePendingLaunch(appID))
        }
        runner.agentsJSON = agentJSON(sessionID: before, alive: false)
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertTrue(runner.commands.contains(["stop", "7d1da24e"]))
            XCTAssertFalse(model.isStopping(appID), "seen gone")
            model.attachIfLive(appID)
            XCTAssertNil(model.takePendingLaunch(appID), "nothing to attach to")
        }
    }

    func testATabShownWithALiveAgentAttaches() async throws {
        runner.agentsJSON = agentJSON(sessionID: before)
        let model = try await MainActor.run { try makeModel() }
        await model.refreshAgents()
        await MainActor.run {
            model.attachIfLive(appID)
            XCTAssertEqual(model.takePendingLaunch(appID)?.claudeArguments, ["attach", "7d1da24e"])
        }
    }
}
