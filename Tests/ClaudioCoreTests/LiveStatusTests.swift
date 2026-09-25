import XCTest
@testable import ClaudioCore

final class LiveStatusTests: XCTestCase {
    let repo = "/Users/tim/Documents/Code/DigiScript"
    let sid = "4a2f8620-a245-4057-ab78-45a6ef0416d3"
    let originalSID = "b3f8f7e8-3932-40da-8035-6f1c5e5cecfd"
    var runner = FakeRunner()

    private func agentJSON(_ id: String, sessionID: String, working: Bool) -> String {
        #"{"pid":88155,"id":"\#(id)","cwd":"\#(repo)","kind":"background","startedAt":1790352615477,"sessionId":"\#(sessionID)","name":"pr review inline","status":"\#(working ? "busy" : "idle")","state":"\#(working ? "working" : "done")"}"#
    }

    private func writeHistory(home: URL, sessionID: String) throws {
        let dir = home.appendingPathComponent("projects").appendingPathComponent(SessionDiscovery.directoryName(forProjectPath: repo))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"\#(repo)","message":{"content":"review 1427"},"timestamp":"2030-01-01T10:00:00Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Posted round 4."}]},"timestamp":"2030-01-01T10:05:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)
    }

    @MainActor private func makeModel(home: URL, hooks: URL) throws -> (AppModel, original: UUID, copy: UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo)
        var original = Session(projectID: p, claudeSessionID: originalSID, hasConversation: true, name: "pr review inline 1427", workingDirectory: repo)
        original.agentID = "b3f8f7e8"
        var copy = Session(projectID: p, claudeSessionID: sid, hasConversation: true, name: "Review #1427", workingDirectory: repo)
        copy.agentID = "4a2f8620"
        try state.workspace.addSession(original)
        try state.workspace.addSession(copy)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: home), hookEventsURL: hooks, runner: runner,
                             locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/zsh", home: "/Users/tim")
        return (model, original.id, copy.id)
    }

    func testHistoryRefreshDoesntOverrideARunningAgentsStatus() async throws {
        let home = try makeTemporaryDirectory()
        try writeHistory(home: home, sessionID: sid)
        let (model, _, copy) = try await MainActor.run { try makeModel(home: home, hooks: home.appendingPathComponent("h.log")) }
        runner.agentsJSON = "[\(agentJSON("4a2f8620", sessionID: sid, working: true))]"
        await model.refreshAgents()
        await MainActor.run { XCTAssertEqual(model.workspace.session(copy)?.status, .working) }
        await model.refreshAll()   // history says the last turn finished
        await MainActor.run { XCTAssertEqual(model.workspace.session(copy)?.status, .working, "the live agent wins") }
    }

    private func hook(_ app: UUID, _ name: String, claudeSession: String, extra: String = "") -> String {
        "\(app.uuidString)\t" + #"{"hook_event_name":"\#(name)","session_id":"\#(claudeSession)"\#(extra)}"# + "\n"
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testHookEventsFromACopyGoToTheCopyNotTheSessionWhoseSettingsItInherited() throws {
        try MainActor.assumeIsolated {
            let home = try makeTemporaryDirectory()
            let hooks = home.appendingPathComponent("h.log")
            let (model, original, copy) = try makeModel(home: home, hooks: hooks)
            // The copy was started with the original's --settings, so its hooks carry the original's app id.
            try append(hook(original, "PreToolUse", claudeSession: sid), to: hooks)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(copy)?.status, .working)
            XCTAssertEqual(model.workspace.session(original)?.status, .completed, "original untouched")
            XCTAssertEqual(model.workspace.session(original)?.claudeSessionID, originalSID, "original keeps its conversation")
        }
    }

    func testEventsForAnUnknownConversationAreIgnored() throws {
        try MainActor.assumeIsolated {
            let home = try makeTemporaryDirectory()
            let hooks = home.appendingPathComponent("h.log")
            let (model, original, _) = try makeModel(home: home, hooks: hooks)
            try append(hook(original, "PreToolUse", claudeSession: "99990000-0000-0000-0000-000000000000"), to: hooks)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(original)?.status, .completed)
            XCTAssertEqual(model.workspace.session(original)?.claudeSessionID, originalSID)
        }
    }

    func testClearFollowsTheNewConversation() throws {
        try MainActor.assumeIsolated {
            let home = try makeTemporaryDirectory()
            let hooks = home.appendingPathComponent("h.log")
            let (model, original, _) = try makeModel(home: home, hooks: hooks)
            let cleared = "77770000-0000-0000-0000-000000000000"
            try append(hook(original, "SessionStart", claudeSession: cleared, extra: #","source":"clear""#), to: hooks)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(original)?.claudeSessionID, cleared)
        }
    }

    func testFirstEventSetsTheConversationOfANewSession() throws {
        try MainActor.assumeIsolated {
            let home = try makeTemporaryDirectory()
            let hooks = home.appendingPathComponent("h.log")
            let (model, _, _) = try makeModel(home: home, hooks: hooks)
            let p = model.workspace.projects[0].id
            let fresh = Session(projectID: p, name: "new", workingDirectory: repo)
            model.applyTestSession(fresh)
            let claude = "55550000-0000-0000-0000-000000000000"
            try append(hook(fresh.id, "UserPromptSubmit", claudeSession: claude, extra: #","prompt":"hi""#), to: hooks)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(fresh.id)?.claudeSessionID, claude)
            XCTAssertEqual(model.workspace.session(fresh.id)?.status, .working)
        }
    }
}
