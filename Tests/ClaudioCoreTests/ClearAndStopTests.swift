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
    private func makeModel(workingDirectory: String? = nil, claudeSessionID: String? = nil, replaced: [String] = [],
                           extra: (UUID) -> [Session] = { _ in [] }) throws -> AppModel {
        home = try makeTemporaryDirectory()
        hooks = try makeTemporaryDirectory().appendingPathComponent("hooks.log")
        try Data().write(to: hooks)
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo)
        var session = Session(id: appID, projectID: p, claudeSessionID: claudeSessionID ?? before, hasConversation: true,
                              name: "Personal Assistant Implementation", workingDirectory: workingDirectory ?? worktree,
                              status: .awaitingInput)
        session.agentID = "7d1da24e"
        session.replacedConversations = replaced
        try state.workspace.addSession(session)
        try extra(p).forEach { try state.workspace.addSession($0) }
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
            // What the list says once `claude stop` has run. Until then the
            // model's last reading has it alive.
            runner.agentsJSON = agentJSON(sessionID: before, alive: false)
            model.stop(appID)
            XCTAssertTrue(model.isStopping(appID))
            model.attachIfLive(appID)
            XCTAssertFalse(model.isRunning(appID))
            XCTAssertNil(model.takePendingLaunch(appID))
        }
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

    /// A copy (started by the CLI) has its original's settings, so its hooks
    /// carry the original's app id. Its `/clear` is its own.
    func testACopysClearStaysWithTheCopy() async throws {
        let original = "c1c1c1c1-0000-0000-0000-000000000000"
        let copyID = UUID()
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel(claudeSessionID: original) { p in
                var copy = Session(id: copyID, projectID: p, claudeSessionID: self.before, hasConversation: true,
                                   name: "Personal Assistant Implementation (copy)", workingDirectory: self.worktree,
                                   status: .awaitingInput)
                copy.agentID = "4b4b4b4b"
                return [copy]
            }
            try clearFromHooks(model)
            XCTAssertEqual(model.workspace.session(copyID)?.claudeSessionID, after)
            XCTAssertEqual(model.workspace.session(copyID)?.replacedConversations, [before])
            XCTAssertEqual(model.workspace.session(appID)?.claudeSessionID, original, "the original is untouched")
            XCTAssertEqual(model.workspace.session(appID)?.replacedConversations, [])
            return model
        }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.sessions.count, 2) }
    }

    /// Should a replaced conversation be another session's own (as a copy's
    /// `/clear` once made it), it's still that session's: synced from its
    /// history, and not deleted with this one.
    func testAReplacedConversationThatsAnothersOwnStaysTheirs() async throws {
        let otherID = UUID()
        let model = try await MainActor.run { () -> AppModel in
            let model = try makeModel(claudeSessionID: before, replaced: [after]) { p in
                [Session(id: otherID, projectID: p, claudeSessionID: self.after, hasConversation: true,
                         name: "other", workingDirectory: self.worktree, status: .awaitingInput)]
            }
            XCTAssertEqual(model.workspace.ownedConversations(of: try XCTUnwrap(model.workspace.session(appID))), [before])
            return model
        }
        await model.refreshAll()
        await MainActor.run {
            XCTAssertEqual(model.workspace.sessions.count, 2)
            model.deleteSession(appID, .everywhere)
        }
        await model.lastTask?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFile(after).path), "the other session's history stays")
        await MainActor.run { XCTAssertFalse(model.workspace.deletedClaudeSessionIDs.contains(after)) }
    }

    /// At launch, history discovery may finish before the first agent list:
    /// it imports the conversation a `/clear` (made while Claudio was
    /// closed) moved to, and the agent's session then takes it over.
    func testClearSeenByDiscoveryBeforeTheAgentList() async throws {
        runner.agentsJSON = agentJSON(sessionID: after)
        let model = try await MainActor.run { try makeModel() }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.sessions.count, 2, "imported before the list was read") }
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertEqual(model.workspace.sessions.map(\.id), [appID])
            XCTAssertEqual(model.workspace.session(appID)?.claudeSessionID, after)
            XCTAssertEqual(model.workspace.session(appID)?.replacedConversations, [before])
        }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.sessions.map(\.id), [appID]) }
    }

    func testAFailedStopLetsTheTabAttachAgain() async throws {
        runner.agentsJSON = agentJSON(sessionID: before)
        runner.stopExit = 1
        let model = try await MainActor.run { try makeModel() }
        await model.refreshAgents()
        await MainActor.run {
            model.stop(appID)
            XCTAssertTrue(model.isStopping(appID))
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertFalse(model.isStopping(appID))
            model.attachIfLive(appID)
            XCTAssertEqual(model.takePendingLaunch(appID)?.claudeArguments, ["attach", "7d1da24e"])
        }
    }

    func testAdoptingAConversation() {
        var s = Session(projectID: UUID(), name: "s", workingDirectory: repo)
        s.adoptConversation("a")
        XCTAssertEqual(s.claudeSessionID, "a")
        XCTAssertEqual(s.replacedConversations, [], "nothing before it")
        s.adoptConversation("")
        XCTAssertEqual(s.claudeSessionID, "a", "an empty id is ignored")
        s.adoptConversation("a")
        XCTAssertEqual(s.replacedConversations, [])
        s.adoptConversation("b")
        s.adoptConversation("a")
        XCTAssertEqual(s.claudeSessionID, "a")
        XCTAssertEqual(s.replacedConversations, ["b"], "back to a: it's current, not replaced")
        s.adoptConversation("b")
        s.adoptConversation("a")
        XCTAssertEqual(s.replacedConversations, ["b"], "no duplicates")
        XCTAssertEqual(s.conversations, ["a", "b"])
    }

    /// The same conversation in the repository's folder and a worktree's:
    /// the newer file wins.
    func testTheNewestHistoryFileWins() throws {
        home = try makeTemporaryDirectory()
        try writeHistory(before, cwd: worktree, text: "in the worktree")
        let inWorktree = historyFile(before)
        let inRepo = home.appendingPathComponent("projects")
            .appendingPathComponent(SessionDiscovery.directoryName(forProjectPath: repo))
            .appendingPathComponent("\(before).jsonl")
        try FileManager.default.createDirectory(at: inRepo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: inRepo)
        let discovery = SessionDiscovery(claudeHome: home)
        let older = Date(timeIntervalSince1970: 1_790_000_000), newer = older.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: inRepo.path)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: inWorktree.path)
        XCTAssertEqual(discovery.newestHistoryFile(projectPath: repo, workingDirectory: repo, claudeSessionID: before)?
                           .deletingLastPathComponent().lastPathComponent, inWorktree.deletingLastPathComponent().lastPathComponent)
        try FileManager.default.setAttributes([.modificationDate: newer.addingTimeInterval(60)], ofItemAtPath: inRepo.path)
        XCTAssertEqual(discovery.newestHistoryFile(projectPath: repo, workingDirectory: repo, claudeSessionID: before)?
                           .deletingLastPathComponent().lastPathComponent, inRepo.deletingLastPathComponent().lastPathComponent)
    }
}
