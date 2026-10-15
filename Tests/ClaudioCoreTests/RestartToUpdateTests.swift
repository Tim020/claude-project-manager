import XCTest
@testable import ClaudioCore

/// Claude Code updates itself while sessions run; their agents stay on the
/// old binary until `claude respawn` restarts them, which also ends the
/// attached terminal, so the tab is attached again.
final class RestartToUpdateTests: XCTestCase {
    let repo = "/code/proj"
    let sessionID = UUID(uuidString: "D2135F55-2ABA-41C4-813D-26E0A5C6CFDE")!
    let conversation = "7d1da24e-122c-4b28-9495-195c4593ed3e"
    let secondID = UUID(uuidString: "6F2D27ED-0B1C-4E0A-9C55-3A2F4A1B7C10")!
    let secondConversation = "fb72709a-291a-41a1-ab00-ed7fe2d9115b"
    var runner = FakeRunner()
    var store = MemoryStore()
    var terminals: FakeTerminals!
    var home: URL!
    var hooks: URL!

    override func setUp() {
        super.setUp()
        runner.versionOutput = "2.1.296 (Claude Code)\n"
        runner.agentsJSON = agentJSON(status: "idle")
    }

    private func agentJSON(id: String = "7d1da24e", name: String = "Project Assistant Import", status: String) -> String {
        #"[{"id":"\#(id)","cwd":"\#(repo)","kind":"background","sessionId":"\#(conversation)","name":"\#(name)","pid":65699,"status":"\#(status)","state":"done"}]"#
    }

    private var rosterURL: URL { DaemonRoster.url(claudeHome: home) }

    /// The recorded roster has 7d1da24e on 2.1.284.
    private func writeRoster(version: String? = nil) throws {
        var text = try Fixtures.string("daemon-roster.json")
        if let version { text = text.replacingOccurrences(of: #""cliVersion": "2.1.284""#, with: #""cliVersion": "\#(version)""#) }
        try FileManager.default.createDirectory(at: rosterURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: rosterURL)
    }

    @MainActor
    private func makeModel(name: String = "Project Assistant Import", backgroundTasks: [BackgroundTask] = [],
                           status: SessionStatus = .completed, needsAction: String? = nil,
                           second: Bool = false) throws -> AppModel {
        home = try makeTemporaryDirectory()
        hooks = try makeTemporaryDirectory().appendingPathComponent("hooks.log")
        try Data().write(to: hooks)
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo)
        var session = Session(id: sessionID, projectID: p, claudeSessionID: conversation, hasConversation: true,
                              name: name, workingDirectory: repo, status: status)
        session.needsAction = needsAction
        session.agentID = "7d1da24e"
        session.backgroundTasks = backgroundTasks
        try state.workspace.addSession(session)
        if second {
            var other = Session(id: secondID, projectID: p, claudeSessionID: secondConversation, hasConversation: true,
                                name: "Websocket Close State", workingDirectory: repo, status: .completed)
            other.agentID = "fb72709a"
            try state.workspace.addSession(other)
        }
        store.state = state
        try writeRoster()
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: home), hookEventsURL: hooks, runner: runner,
                             locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil },
                             shell: "/bin/zsh", home: "/home/u")
        terminals = FakeTerminals()
        model.terminals = terminals
        return model
    }

    /// Checks the CLI (2.1.296) and lists the agent, which runs 2.1.284.
    private func readyModel(name: String = "Project Assistant Import", backgroundTasks: [BackgroundTask] = [],
                            status: SessionStatus = .completed, needsAction: String? = nil,
                            second: Bool = false) async throws -> AppModel {
        let model = try await MainActor.run {
            try makeModel(name: name, backgroundTasks: backgroundTasks, status: status, needsAction: needsAction, second: second)
        }
        await model.checkEnvironment(force: true)
        await model.refreshAgents()
        await model.lastTask?.value
        return model
    }

    private func respawnCommands() -> [[String]] {
        runner.commands.filter { $0.first == "respawn" }
    }

    // MARK: Parsing

    func testRosterGivesEachAgentsVersion() throws {
        let versions = try XCTUnwrap(DaemonRoster.versions(Data(try Fixtures.string("daemon-roster.json").utf8)))
        XCTAssertEqual(versions, ["fb72709a": ClaudeVersion(2, 1, 281), "7d1da24e": ClaudeVersion(2, 1, 284),
                                  "52f972c5": ClaudeVersion(2, 1, 300)])
        XCTAssertNil(DaemonRoster.versions(Data("[]".utf8)))
        XCTAssertEqual(DaemonRoster.versions(Data(#"{"workers":{"a":{"pid":1}}}"#.utf8)), [:])
    }

    /// Output from 2.1.296 in a container, and its source for an id change.
    func testRespawnOutput() {
        XCTAssertEqual(RespawnResult.parse(exitCode: 0, output: "respawned 1cc21cfa\n", errorOutput: ""), .respawned(agentID: "1cc21cfa"))
        XCTAssertEqual(RespawnResult.parse(exitCode: 0, output: "respawned 1cc21cfa → 9e454d54\n", errorOutput: ""),
                       .respawned(agentID: "9e454d54"))
        XCTAssertEqual(RespawnResult.parse(exitCode: 1, output: "", errorOutput: "No job matching 'deadbeef'\n"),
                       .failed("No job matching 'deadbeef'"))
        XCTAssertEqual(RespawnResult.parse(exitCode: 1, output: "",
                                           errorOutput: "1cc21cfa: still running — couldn't confirm restart, retry in a moment\n"),
                       .stillRunning)
        XCTAssertEqual(RespawnResult.parse(exitCode: 1, output: "", errorOutput: ""), .failed("exit 1"))
        XCTAssertEqual(RespawnResult.parse(exitCode: 0, output: "", errorOutput: ""), .failed("claude respawn didn't say it restarted"))
        XCTAssertEqual(RespawnResult.parse(exitCode: 0, output: "restarting 1cc21cfa\n", errorOutput: ""),
                       .failed("claude respawn didn't say it restarted (restarting 1cc21cfa)"))
    }

    func testRespawnCommand() {
        let commands = AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/tmp/h.log")
        XCTAssertEqual(commands.respawn(agentID: "7d1da24e").claudeArguments, ["respawn", "7d1da24e"])
    }

    // MARK: Which sessions

    func testAnAgentOnAnOlderVersionIsOutdated() async throws {
        let model = try await readyModel()
        await MainActor.run {
            XCTAssertEqual(model.agentVersions["7d1da24e"], ClaudeVersion(2, 1, 284))
            XCTAssertEqual(model.outdatedVersion(of: sessionID), ClaudeVersion(2, 1, 284))
            XCTAssertEqual(model.outdatedSessionIDs, [sessionID])
            XCTAssertTrue(model.canRestartToUpdate(sessionID))
            model.updateMenuFlags()
            XCTAssertEqual(model.menuFlags.restartableCount, 1)
        }
    }

    func testAnAgentOnTheInstalledVersionIsNot() async throws {
        let model = try await MainActor.run { try makeModel() }
        try writeRoster(version: "2.1.296")
        await model.checkEnvironment(force: true)
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertNil(model.outdatedVersion(of: sessionID))
            XCTAssertFalse(model.canRestartToUpdate(sessionID))
        }
    }

    func testAStoppedAgentIsNotOutdated() async throws {
        runner.agentsJSON = #"[{"id":"7d1da24e","cwd":"/code/proj","kind":"background","sessionId":"\#(conversation)","state":"stopped"}]"#
        let model = try await readyModel()
        await MainActor.run { XCTAssertNil(model.outdatedVersion(of: sessionID), "resuming it starts the new version anyway") }
    }

    /// `claude respawn` doesn't wait for the turn to end.
    func testABusyAgentWaits() async throws {
        runner.agentsJSON = agentJSON(status: "busy")
        let model = try await readyModel()
        await MainActor.run {
            XCTAssertNotNil(model.outdatedVersion(of: sessionID))
            XCTAssertEqual(model.restartBlocker(sessionID), "Wait until it's idle")
            model.restartToUpdate(sessionID)
            XCTAssertTrue(model.restartingSessions.isEmpty)
        }
        await model.lastTask?.value
        XCTAssertEqual(respawnCommands(), [])
    }

    /// An agent at a permission prompt is listed `status: "waiting"`.
    func testAnAgentWaitingForAnAnswerSaysSo() async throws {
        runner.agentsJSON = agentJSON(status: "waiting")
        let model = try await readyModel()
        await MainActor.run { XCTAssertEqual(model.restartBlocker(sessionID), "It's waiting for your answer") }
    }

    func testASessionWithoutAnAgentIsntRestarted() async throws {
        let model = try await readyModel()
        await MainActor.run {
            XCTAssertEqual(model.restartBlocker(UUID()), "Not a background agent")
        }
    }

    /// Most installs have no roster until a background agent has run.
    func testNoRosterMeansNothingIsOutdated() async throws {
        let model = try await MainActor.run { try makeModel() }
        try FileManager.default.removeItem(at: rosterURL)
        await model.checkEnvironment(force: true)
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertEqual(model.agentVersions, [:])
            XCTAssertEqual(model.outdatedSessionIDs, [])
            model.updateMenuFlags()
            XCTAssertEqual(model.menuFlags.restartableCount, 0)
            XCTAssertFalse(model.log.entries.contains { $0.title == "Couldn't read Claude Code's agent roster" })
        }
    }

    /// A roster read mid-write keeps the versions read before, and says so.
    func testAnUnreadableRosterKeepsTheLastVersions() async throws {
        let model = try await readyModel()
        try Data("{\"workers\":".utf8).write(to: rosterURL)
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertEqual(model.outdatedVersion(of: sessionID), ClaudeVersion(2, 1, 284))
            XCTAssertTrue(model.log.entries.contains { $0.title == "Couldn't read Claude Code's agent roster" })
        }
    }

    /// Unreadable twice in a row is a roster Claudio can't read at all
    /// (a CLI that changed its shape): no versions are trusted then.
    func testARosterUnreadableTwiceIsntTrusted() async throws {
        let model = try await readyModel()
        try Data("{\"workers\":".utf8).write(to: rosterURL)
        await model.refreshAgents()
        await MainActor.run { XCTAssertNotNil(model.outdatedVersion(of: sessionID)) }
        try Data(#"{"workers":[]}"#.utf8).write(to: rosterURL)
        await model.refreshAgents()
        await MainActor.run {
            XCTAssertEqual(model.agentVersions, [:])
            XCTAssertNil(model.outdatedVersion(of: sessionID))
        }
        try writeRoster()
        await model.refreshAgents()
        await MainActor.run { XCTAssertNotNil(model.outdatedVersion(of: sessionID), "readable again") }
    }

    func testRunningBackgroundTasksWait() async throws {
        let task = BackgroundTask(id: "b1", kind: "shell", description: "npm run dev", since: Date())
        let model = try await readyModel(backgroundTasks: [task])
        await MainActor.run {
            XCTAssertEqual(model.restartBlocker(sessionID), "Background tasks are still running")
            XCTAssertFalse(model.canRestartToUpdate(sessionID))
        }
    }

    /// Claude Code updated itself since the last check: an agent on a newer
    /// version than the installed one makes Claudio check again.
    func testANewerAgentChecksTheCLIAgain() async throws {
        runner.versionOutput = "2.1.284 (Claude Code)\n"
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment(force: true)
        // 52f972c5 runs 2.1.300.
        runner.versionOutput = "2.1.300 (Claude Code)\n"
        try writeRoster(version: "2.1.300")
        await model.refreshAgents()
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(model.environment.version, ClaudeVersion(2, 1, 300))
            XCTAssertEqual(model.outdatedSessionIDs, [], "7d1da24e is on 2.1.300 too now")
        }
        let checks = runner.commands.filter { $0 == ["--version"] }.count
        await model.refreshAgents()
        await model.lastTask?.value
        XCTAssertEqual(runner.commands.filter { $0 == ["--version"] }.count, checks, "once per version")
    }

    // MARK: Restarting

    /// The restart ends the attached terminal; when that exit comes after the
    /// restart has finished, it attaches the tab again.
    func testRestartingAnAttachedTabAttachesItAgain() async throws {
        let model = try await readyModel()
        let roster = rosterURL
        runner.duringRespawn = {
            let text = try! String(contentsOf: roster, encoding: .utf8)
            try! text.replacingOccurrences(of: "2.1.284", with: "2.1.296").write(to: roster, atomically: true, encoding: .utf8)
        }
        await MainActor.run {
            model.resume(sessionID)
            XCTAssertEqual(model.takePendingLaunch(sessionID)?.claudeArguments, ["attach", "7d1da24e"])
            model.restartToUpdate(sessionID)
            XCTAssertEqual(model.restartingSessions, [sessionID])
            model.attachIfLive(sessionID)
            XCTAssertNil(model.takePendingLaunch(sessionID), "nothing attaches while it restarts")
        }
        await model.lastTask?.value
        XCTAssertEqual(respawnCommands(), [["respawn", "7d1da24e"]])
        await MainActor.run {
            XCTAssertTrue(model.restartingSessions.isEmpty)
            XCTAssertNil(model.outdatedVersion(of: sessionID))
            XCTAssertNil(model.takePendingLaunch(sessionID), "the old terminal is still going")
            model.terminalExited(sessionID, exitCode: 0)
            XCTAssertTrue(model.isRunning(sessionID))
            XCTAssertEqual(model.takePendingLaunch(sessionID)?.claudeArguments, ["attach", "7d1da24e"])
            XCTAssertTrue(model.log.entries.contains { $0.title == "Restarted “Project Assistant Import” on the installed Claude Code" })
        }
    }

    /// The terminal exits mid-restart: the restart attaches once it's done.
    func testATerminalThatExitsMidRestartIsAttachedAfterward() async throws {
        let model = try await readyModel()
        let roster = rosterURL
        let id = sessionID
        runner.duringRespawn = {
            await MainActor.run {
                model.terminalExited(id, exitCode: 0)
                XCTAssertNil(model.takePendingLaunch(id), "not yet: the agent is still coming back")
            }
            let text = try! String(contentsOf: roster, encoding: .utf8)
            try! text.replacingOccurrences(of: "2.1.284", with: "2.1.296").write(to: roster, atomically: true, encoding: .utf8)
        }
        await MainActor.run {
            model.resume(sessionID)
            _ = model.takePendingLaunch(sessionID)
            model.restartToUpdate(sessionID)
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertTrue(model.isRunning(sessionID))
            XCTAssertEqual(model.takePendingLaunch(sessionID)?.claudeArguments, ["attach", "7d1da24e"])
        }
    }

    func testANewIDIsKept() async throws {
        runner.respawnOutput = "respawned 7d1da24e → 9e454d54\n"
        let model = try await readyModel()
        let (runner, roster, listed) = (runner, rosterURL, agentJSON(id: "9e454d54", status: "idle"))
        runner.duringRespawn = {
            runner.agentsJSON = listed
            try! Data(#"{"workers":{"9e454d54":{"cliVersion":"2.1.296"}}}"#.utf8).write(to: roster)
        }
        await MainActor.run { model.restartToUpdate(sessionID) }
        await model.lastTask?.value
        await MainActor.run { XCTAssertEqual(model.workspace.session(sessionID)?.agentID, "9e454d54") }
        XCTAssertEqual(store.state.workspace.session(sessionID)?.agentID, "9e454d54", "saved")
    }

    func testAFailedRestartSaysWhyAndLeavesTheTab() async throws {
        runner.respawnExit = 1
        runner.respawnError = "No job matching '7d1da24e'\n"
        let model = try await readyModel()
        await MainActor.run {
            model.resume(sessionID)
            _ = model.takePendingLaunch(sessionID)
            model.restartToUpdate(sessionID)
        }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(model.errorMessage, "Couldn't restart “Project Assistant Import”: No job matching '7d1da24e'")
            XCTAssertTrue(model.restartingSessions.isEmpty)
            model.terminalExited(sessionID, exitCode: 0)
            XCTAssertFalse(model.isRunning(sessionID), "closing the tab later doesn't attach it again")
        }
    }

    func testRestartAllRestartsEachIdleOutdatedSession() async throws {
        let both = String(agentJSON(status: "idle").dropLast()) + "," + String(agentJSON(status: "idle")
            .replacingOccurrences(of: "7d1da24e-122c-4b28-9495-195c4593ed3e", with: secondConversation)
            .replacingOccurrences(of: "7d1da24e", with: "fb72709a")
            .replacingOccurrences(of: "Project Assistant Import", with: "Websocket Close State").dropFirst())
        runner.agentsJSON = both
        let model = try await readyModel(second: true)
        let roster = rosterURL
        runner.duringRespawn = {
            try! Data(#"{"workers":{"7d1da24e":{"cliVersion":"2.1.296"},"fb72709a":{"cliVersion":"2.1.296"}}}"#.utf8).write(to: roster)
        }
        await MainActor.run {
            XCTAssertEqual(Set(model.outdatedSessionIDs), [sessionID, secondID])
            model.restartAllToUpdate()
            XCTAssertEqual(model.restartingSessions, [sessionID, secondID])
        }
        await model.lastTask?.value
        XCTAssertEqual(Set(respawnCommands()), [["respawn", "7d1da24e"], ["respawn", "fb72709a"]])
        await MainActor.run {
            XCTAssertEqual(model.outdatedSessionIDs, [])
            XCTAssertTrue(model.restartingSessions.isEmpty)
        }
    }

    /// Stopping a session, or closing its tab, mid-restart: neither reattach
    /// path brings its terminal back, whichever comes first, the restart or
    /// the old terminal's exit.
    func testStoppingMidRestartDoesntAttachAgain() async throws {
        for (exitFirst, closeOnly) in [(false, false), (true, false), (false, true), (true, true)] {
            runner = FakeRunner()
            runner.versionOutput = "2.1.296 (Claude Code)\n"
            runner.agentsJSON = agentJSON(status: "idle")
            let model = try await readyModel()
            let (runner, roster, id) = (runner, rosterURL, sessionID)
            runner.duringRespawn = {
                await MainActor.run {
                    if closeOnly { model.closeTab(id) } else { model.stop(id) }
                    if exitFirst { model.terminalExited(id, exitCode: 0) }
                }
                try! Data(#"{"workers":{"7d1da24e":{"cliVersion":"2.1.296"}}}"#.utf8).write(to: roster)
            }
            await MainActor.run {
                model.resume(id)
                _ = model.takePendingLaunch(id)
                model.restartToUpdate(id)
            }
            await model.lastTask?.value
            // The stop was queued mid-restart, after the task awaited above.
            await model.lastTask?.value
            await MainActor.run {
                if !exitFirst { model.terminalExited(id, exitCode: 0) }
                XCTAssertNil(model.takePendingLaunch(id), "exit first: \(exitFirst), close only: \(closeOnly)")
                XCTAssertFalse(model.isRunning(id), "exit first: \(exitFirst), close only: \(closeOnly)")
            }
            XCTAssertEqual(runner.commands.contains(["stop", "7d1da24e"]), !closeOnly)
            if closeOnly {
                // Reopening it attaches as usual.
                await MainActor.run {
                    model.resume(id)
                    XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments, ["attach", "7d1da24e"])
                }
            }
        }
    }

    /// A restart that fails because the agent really went: the stop is
    /// still reported (compared with the baseline from before the restart).
    func testAnAgentThatWentDuringAFailedRestartIsReported() async throws {
        runner.respawnExit = 1
        runner.respawnError = "No job matching '7d1da24e'\n"
        let model = try await readyModel()
        let notifier = await MainActor.run { FakeNotifier() }
        let (runner, gone) = (runner,
            #"[{"id":"7d1da24e","cwd":"/code/proj","kind":"background","sessionId":"\#(conversation)","state":"working"}]"#)
        await MainActor.run {
            var settings = model.settings
            settings.notifications.stoppedUnexpectedly = true
            model.updateSettings(settings)
            model.notifier = notifier
            model.checkNotifications()
        }
        runner.duringRespawn = {
            runner.agentsJSON = gone
            await model.refreshAgents()
            await MainActor.run { model.checkNotifications() }
        }
        await MainActor.run { model.restartToUpdate(sessionID) }
        await model.lastTask?.value
        await MainActor.run {
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.map(\.title), ["Project Assistant Import stopped unexpectedly"])
        }
    }

    /// A respawn that hangs is cut off; the agent list decides whether it
    /// restarted.
    func testATimedOutRespawnCountsIfTheAgentCameBackUpdated() async throws {
        runner.respawnExit = 1
        runner.respawnTimedOut = true
        let model = try await readyModel()
        let roster = rosterURL
        runner.duringRespawn = { try! Data(#"{"workers":{"7d1da24e":{"cliVersion":"2.1.296"}}}"#.utf8).write(to: roster) }
        await MainActor.run { model.restartToUpdate(sessionID) }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertNil(model.errorMessage)
            XCTAssertNil(model.outdatedVersion(of: sessionID))
        }
    }

    /// A respawn that timed out with the agent not back yet may only be slow:
    /// it says it couldn't confirm the restart, and isn't reported as a stop.
    func testATimedOutUnconfirmedRespawnIsntReportedAsAStop() async throws {
        runner.respawnExit = 1
        runner.respawnTimedOut = true
        let model = try await readyModel()
        let notifier = await MainActor.run { FakeNotifier() }
        let (runner, gone) = (runner,
            #"[{"id":"7d1da24e","cwd":"/code/proj","kind":"background","sessionId":"\#(conversation)","state":"working"}]"#)
        await MainActor.run {
            var settings = model.settings
            settings.notifications.stoppedUnexpectedly = true
            model.updateSettings(settings)
            model.notifier = notifier
            model.checkNotifications()
        }
        runner.duringRespawn = { runner.agentsJSON = gone }
        await MainActor.run { model.restartToUpdate(sessionID) }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertEqual(model.errorMessage, "Couldn't confirm “Project Assistant Import” restarted. Try again in a moment.")
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.map(\.title), [])
        }
    }

    /// Mid-restart the agent is listed with no process (for about 200 ms in a
    /// container) while its task may still say "working" (the shape of a
    /// stop), and a question it ended on would be dropped. The hooks then say
    /// SessionEnd and SessionStart(resume) (`Fixtures/hook-respawn.log`,
    /// Claudio's own hook settings, 2.1.296). None of it is news.
    func testTheRestartIsntNotifiedAndAQuestionStillStands() async throws {
        let model = try await readyModel(status: .awaitingInput, needsAction: "Ship it?")
        let notifier = await MainActor.run { FakeNotifier() }
        let (runner, roster, gone, back) = (runner, rosterURL,
            #"[{"id":"7d1da24e","cwd":"/code/proj","kind":"background","sessionId":"\#(conversation)","state":"working"}]"#,
            agentJSON(status: "idle"))
        let id = sessionID
        let hookLog = hooks!
        let hookLines = try Fixtures.string("hook-respawn.log")
            .replacingOccurrences(of: "47D01FE4-818B-4DCF-92ED-5AA4EE663D07", with: id.uuidString)
            .replacingOccurrences(of: "ee6773dd-9608-4494-83ef-537d2fa94135", with: conversation)
        await MainActor.run {
            var settings = model.settings
            settings.notifications.stoppedUnexpectedly = true
            settings.notifications.finished = true
            settings.notifications.awaitingInput = true
            model.updateSettings(settings)
            model.notifier = notifier
            XCTAssertEqual(model.workspace.session(id)?.status, .awaitingInput)
            model.checkNotifications()
        }
        runner.duringRespawn = {
            runner.agentsJSON = gone
            await model.refreshAgents()
            try! Data(hookLines.utf8).write(to: hookLog)
            await MainActor.run {
                model.pollHookEvents()
                model.checkNotifications()
            }
            runner.agentsJSON = back
            try! Data(#"{"workers":{"7d1da24e":{"cliVersion":"2.1.296"}}}"#.utf8).write(to: roster)
        }
        await MainActor.run { model.restartToUpdate(id) }
        await model.lastTask?.value
        await MainActor.run {
            model.checkNotifications()
            model.checkNotifications()
            XCTAssertEqual(notifier.posted.map(\.title), [])
            XCTAssertEqual(model.workspace.session(id)?.status, .awaitingInput)
            XCTAssertEqual(model.workspace.session(id)?.needsAction, "Ship it?")
        }
        await model.refreshAgents()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.status, .awaitingInput, "the idle agent keeps it") }
    }

    func testARestartDoesntOfferAFollowUp() async throws {
        let model = try await readyModel()
        let roster = rosterURL
        runner.duringRespawn = { try! Data(#"{"workers":{"7d1da24e":{"cliVersion":"2.1.296"}}}"#.utf8).write(to: roster) }
        await MainActor.run {
            model.resume(sessionID)
            _ = model.takePendingLaunch(sessionID)
            model.followUpDue.removeAll()
            model.restartToUpdate(sessionID)
        }
        await model.lastTask?.value
        await MainActor.run {
            model.terminalExited(sessionID, exitCode: 0)
            XCTAssertFalse(model.followUpDue.contains(sessionID))
        }
    }

    // MARK: Names

    /// After `claude respawn`, an agent Claude Code hadn't titled yet was
    /// listed under its id (2.1.296, in a container).
    func testAnAgentListedUnderItsIDKeepsTheSessionsName() async throws {
        runner.agentsJSON = agentJSON(name: "7d1da24e", status: "idle")
        let model = try await readyModel()
        await MainActor.run { XCTAssertEqual(model.workspace.session(sessionID)?.name, "Project Assistant Import") }
        runner.agentsJSON = agentJSON(name: "project assistant import", status: "idle")
        await model.refreshAgents()
        await MainActor.run { XCTAssertEqual(model.workspace.session(sessionID)?.name, "project assistant import") }
    }
}
