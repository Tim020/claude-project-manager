import XCTest
@testable import ClaudioCore

/// Resuming a stopped background agent must continue that agent. With extra
/// flags (--model, --settings…) Claude Code 2.1.282 starts a copy instead:
/// "background session b3f8f7e8 keeps its own saved options, so the flags you
/// passed started a copy as 4a2f8620. Without flags, the same command
/// continues b3f8f7e8 itself."
final class ResumeAgentTests: XCTestCase {
    let repo = "/Users/tim/Documents/Code/DigiScript"
    let sid = "b3f8f7e8-3932-40da-8035-6f1c5e5cecfd"
    var store = MemoryStore()
    var runner = FakeRunner()
    var terminals: FakeTerminals!

    func testContinuingAnAgentPassesNoFlags() {
        var session = Session(projectID: UUID(), claudeSessionID: sid, hasConversation: true, name: "s", workingDirectory: repo,
                              model: "claude-opus-5-5")
        session.agentID = "b3f8f7e8"
        let commands = AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/tmp/h.log")
        XCTAssertEqual(commands.resume(session: session, prompt: "/review-pr-inline 1427", continuingAgent: true).claudeArguments,
                       ["/review-pr-inline 1427", "--bg", "--resume", sid])
        XCTAssertTrue(commands.resume(session: session, prompt: nil).claudeArguments.contains("--settings"),
                      "a session that was never an agent still gets Claudio's hooks")
    }

    func testRecognisesTheNewCopyNote() {
        let stderr = "note: background session b3f8f7e8 keeps its own saved options, so the flags you passed started a copy as 4a2f8620. Without flags, the same command continues b3f8f7e8 itself."
        XCTAssertEqual(AgentListParser.copiedID(from: stderr), "4a2f8620")
    }

    @MainActor private func makeModel() throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo)
        let f = try state.workspace.createFolder(in: p, named: "Websocket Close State")
        var session = Session(projectID: p, claudeSessionID: sid, hasConversation: true, name: "pr review inline 1427",
                              workingDirectory: repo, model: "claude-opus-5-5")
        session.agentID = "b3f8f7e8"
        session.hasCustomName = true
        try state.workspace.addSession(session, toFolder: f)
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("hooks.log"), runner: runner,
                             locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil }, shell: "/bin/zsh",
                             now: { Date(timeIntervalSince1970: 1_790_352_600) }, home: "/Users/tim")
        terminals = FakeTerminals()
        model.terminals = terminals
        return (model, session.id)
    }

    private func agent(_ id: String, sessionID: String, name: String, pid: Int? = nil, state: String) -> String {
        let pidField = pid.map { #""pid":\#($0),"# } ?? ""
        return #"{\#(pidField)"id":"\#(id)","cwd":"\#(repo)","kind":"background","startedAt":1790283501362,"sessionId":"\#(sessionID)","name":"\#(name)","state":"\#(state)"}"#
    }

    func testResumingAStoppedAgentContinuesIt() async throws {
        let (model, id) = try await MainActor.run { try makeModel() }
        runner.agentsJSON = "[\(agent("b3f8f7e8", sessionID: sid, name: "pr review inline 1427", state: "done"))]"
        await model.refreshAgents()
        runner.dispatchOutput = "backgrounded · b3f8f7e8\n"
        await MainActor.run { model.resume(id, message: "/review-pr-inline 1427") }
        await model.lastTask?.value
        try await MainActor.run {
            let resume = try XCTUnwrap(runner.commands.last { $0.contains("--bg") })
            XCTAssertEqual(resume, ["/review-pr-inline 1427", "--bg", "--resume", sid])
            XCTAssertEqual(model.workspace.sessions.count, 1)
            XCTAssertEqual(model.workspace.session(id)?.agentID, "b3f8f7e8")
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments, ["attach", "b3f8f7e8"])
        }
    }

    func testIfTheCLICopiesAnywayTheCopyIsItsOwnSessionAndTheOriginalKeepsItsAgent() async throws {
        let (model, id) = try await MainActor.run { try makeModel() }
        runner.agentsJSON = "[\(agent("b3f8f7e8", sessionID: sid, name: "pr review inline 1427", state: "done"))]"
        await model.refreshAgents()
        runner.dispatchOutput = "backgrounded · 4a2f8620\nnote: background session b3f8f7e8 keeps its own saved options, so the flags you passed started a copy as 4a2f8620.\n"
        await MainActor.run { model.resume(id) }
        await model.lastTask?.value
        runner.agentsJSON = "[\(agent("b3f8f7e8", sessionID: sid, name: "pr review inline 1427", state: "done")),"
            + "\(agent("4a2f8620", sessionID: "4a2f8620-a245-4057-ab78-45a6ef0416d3", name: "pr review inline", pid: 88155, state: "working"))]"
        await model.refreshAgents()
        try await MainActor.run {
            XCTAssertEqual(model.workspace.sessions.count, 2, "no third, duplicate session")
            XCTAssertEqual(model.workspace.session(id)?.agentID, "b3f8f7e8")
            XCTAssertEqual(model.workspace.session(id)?.claudeSessionID, sid)
            let copy = try XCTUnwrap(model.workspace.sessions.first { $0.id != id })
            XCTAssertEqual(copy.agentID, "4a2f8620")
            XCTAssertEqual(copy.claudeSessionID, "4a2f8620-a245-4057-ab78-45a6ef0416d3")
        }
    }

    func testAgentIDMatchWinsOverASharedConversationID() async throws {
        // A session linked to agent X must not be re-pointed at agent Y just
        // because Y lists the session's old conversation id.
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let (model, id) = try makeModel()
            return (model, id)
        }
        await MainActor.run {
            model.applyAgentLink(id, agentID: "4a2f8620")
        }
        runner.agentsJSON = "[\(agent("b3f8f7e8", sessionID: sid, name: "pr review inline 1427", state: "done")),"
            + "\(agent("4a2f8620", sessionID: "4a2f8620-a245-4057-ab78-45a6ef0416d3", name: "pr review inline", pid: 88155, state: "working"))]"
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertEqual(model.workspace.session(id)?.agentID, "4a2f8620", "keeps the agent its terminal is attached to")
            XCTAssertEqual(model.workspace.session(id)?.claudeSessionID, "4a2f8620-a245-4057-ab78-45a6ef0416d3")
        }
    }
}
