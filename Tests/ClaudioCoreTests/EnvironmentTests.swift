import XCTest
@testable import ClaudioCore

final class EnvironmentParsingTests: XCTestCase {
    func testParsesVersions() {
        XCTAssertEqual(ClaudeVersion.parse("2.1.283 (Claude Code)\n"), ClaudeVersion(2, 1, 283))
        XCTAssertEqual(ClaudeVersion.parse("Current version: 2.1.283"), ClaudeVersion(2, 1, 283))
        XCTAssertNil(ClaudeVersion.parse("claude: command not found"))
        XCTAssertLessThan(ClaudeVersion(2, 1, 99), ClaudeVersion(2, 1, 282))
        XCTAssertLessThan(ClaudeVersion(1, 9, 999), ClaudeVersion(2, 0, 0))
        XCTAssertEqual(ClaudeVersion(2, 1, 283).description, "2.1.283")
    }

    func testParsesAuthStatus() throws {
        // Recorded from `claude auth status` (2.1.283), with the account details replaced.
        let signedIn = """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "firstParty",
          "analyticsDisabled": false,
          "projectsDirectory": "/Users/tim/.claude/projects",
          "configDirectory": "/Users/tim/.claude",
          "email": "tim@example.com",
          "orgId": "00000000-0000-0000-0000-000000000000",
          "orgName": "Tim's Organization",
          "subscriptionType": "pro"
        }
        """
        let status = try XCTUnwrap(ClaudeAuthStatus.parse(signedIn))
        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.method, "claude.ai")
        XCTAssertEqual(status.plan, "pro")
        XCTAssertEqual(status.planLabel, "Claude Pro")
        XCTAssertEqual(ClaudeAuthStatus.parse(#"{"loggedIn": false}"#)?.loggedIn, false)
        XCTAssertNil(ClaudeAuthStatus.parse("error: unknown command 'auth'"))
        XCTAssertEqual(ClaudeAuthStatus(loggedIn: true, method: "apiKey").planLabel, "apiKey")
    }

    func testProblemsAndWhatTheyBlock() {
        var env = ClaudeEnvironment()
        XCTAssertTrue(env.canRunSessions, "nothing is blocked before the first check")
        XCTAssertEqual(env.problems, [])

        env.install = .notFound
        XCTAssertEqual(env.problems, [.notInstalled])
        XCTAssertFalse(env.canRunSessions)
        XCTAssertEqual(env.blockedReason, "Claude Code isn't installed")

        env.install = .installed(path: "/c", version: ClaudeVersion(2, 0, 30))
        env.signIn = .signedOut
        env.agents = .unsupported(message: "unknown command")
        XCTAssertEqual(env.problems, [.outdated(ClaudeVersion(2, 0, 30)), .signedOut, .agentsUnsupported])
        XCTAssertFalse(env.canRunSessions)
        XCTAssertFalse(env.backgroundAgentsAvailable)
        XCTAssertEqual(env.problems.map(\.fix), [.update, .signIn, .update])
        XCTAssertEqual(env.problems.filter(\.isBlocking), [.signedOut])

        env.signIn = .unknown
        XCTAssertTrue(env.canRunSessions, "an unanswered sign-in check doesn't block")
    }
}

final class EnvironmentCheckTests: XCTestCase {
    var runner = FakeRunner()
    var located: String? = "/Users/tim/.local/bin/claude"
    var clock = Date(timeIntervalSince1970: 1_790_340_000)

    @MainActor private func makeModel() throws -> AppModel {
        var state = PersistedState()
        _ = state.workspace.addProject(path: "/code")
        let store = MemoryStore()
        store.state = state
        return AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                        hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                        locateClaude: { [unowned self] _ in self.located }, shell: "/bin/zsh",
                        now: { [unowned self] in self.clock }, home: "/Users/tim")
    }

    func testAllGood() async throws {
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run {
            XCTAssertEqual(model.environment.install, .installed(path: "/Users/tim/.local/bin/claude", version: ClaudeVersion(2, 1, 283)))
            XCTAssertEqual(model.environment.agents, .supported)
            XCTAssertEqual(model.environment.problems, [])
            if case .signedIn(let status) = model.environment.signIn { XCTAssertEqual(status.plan, "pro") } else { XCTFail() }
            XCTAssertTrue(model.backgroundAgentsEnabled)
        }
    }

    func testAccountDetailsStayOutOfTheLog() async throws {
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run {
            XCTAssertFalse(model.log.entries.contains { ($0.detail ?? "").contains("tim@example.com") })
            XCTAssertTrue(model.log.entries.contains { $0.title == "claude auth status --json" })
        }
    }

    func testNotInstalled() async throws {
        located = nil
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run {
            XCTAssertEqual(model.environment.problems, [.notInstalled])
            XCTAssertFalse(model.environment.canRunSessions)
            XCTAssertTrue(runner.commands.isEmpty, "nothing to run")
        }
        await model.refreshAgents()
        await model.refreshUsage()
        XCTAssertTrue(runner.commands.isEmpty, "polling stops while claude is missing")
    }

    func testBrokenInstall() async throws {
        runner.versionExit = 127
        runner.versionError = "env: node: No such file or directory\n"
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run {
            XCTAssertEqual(model.environment.problems, [.broken("env: node: No such file or directory")])
            XCTAssertEqual(model.environment.problems.first?.fix, .chooseExecutable)
        }
    }

    func testSignedOut() async throws {
        // Recorded from 2.1.283 with an empty config: JSON, and exit code 1.
        runner.authOutput = """
        {
          "loggedIn": false,
          "authMethod": "none",
          "apiProvider": "firstParty",
          "analyticsDisabled": false,
          "projectsDirectory": "/root/.claude/projects",
          "configDirectory": "/root/.claude"
        }
        """
        runner.authExit = 1
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run {
            XCTAssertEqual(model.environment.signIn, .signedOut)
            XCTAssertEqual(model.environment.problems, [.signedOut])
            XCTAssertFalse(model.environment.canRunSessions)
        }
    }

    func testOldCLIWithoutAgentsFallsBackToDirectSessions() async throws {
        // Recorded from 2.0.30: both commands reject --json.
        runner.versionOutput = "2.0.30 (Claude Code)"
        runner.authOutput = ""
        runner.authExit = 1
        runner.agentsExit = 1
        runner.agentsError = "error: unknown option '--json'\n"
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run {
            XCTAssertEqual(model.environment.signIn, .unknown)
            XCTAssertEqual(model.environment.problems, [.outdated(ClaudeVersion(2, 0, 30)), .agentsUnsupported])
            XCTAssertTrue(model.environment.canRunSessions)
            XCTAssertTrue(model.settings.useBackgroundAgents, "the setting itself is untouched")
            XCTAssertFalse(model.backgroundAgentsEnabled)
        }
    }

    func testAVersionWithBackgroundAgentsButNoAgentsListIsTreatedAsUnsupported() async throws {
        // Recorded from 2.1.168: --bg and attach exist, but not `agents --all`.
        runner.versionOutput = "2.1.168 (Claude Code)"
        runner.agentsExit = 1
        runner.agentsError = "error: unknown option '--all'\n"
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run {
            XCTAssertEqual(model.environment.problems, [.outdated(ClaudeVersion(2, 1, 168)), .agentsUnsupported])
            XCTAssertFalse(model.backgroundAgentsEnabled)
        }
    }

    func testTheMinimumVersionIsFine() async throws {
        runner.versionOutput = "2.1.169 (Claude Code)"
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        await MainActor.run { XCTAssertEqual(model.environment.problems, []) }
    }

    func testChecksAreThrottledUnlessForced() async throws {
        let model = try await MainActor.run { try makeModel() }
        await model.checkEnvironment()
        let count = runner.commands.count
        await model.checkEnvironment()
        XCTAssertEqual(runner.commands.count, count, "fresh result reused")
        await model.checkEnvironment(force: true)
        XCTAssertGreaterThan(runner.commands.count, count)
        clock = clock.addingTimeInterval(AppModel.environmentCheckInterval + 1)
        let before = runner.commands.count
        await model.checkEnvironment()
        XCTAssertGreaterThan(runner.commands.count, before, "stale result re-checked")
    }

    func testFixCommands() async throws {
        let model = try await MainActor.run { try makeModel() }
        await MainActor.run {
            XCTAssertEqual(model.fixLaunch(for: .update)?.claudeArguments, ["update"])
            XCTAssertEqual(model.fixLaunch(for: .signIn)?.claudeArguments, ["auth", "login"])
            let install = model.fixLaunch(for: .install)
            XCTAssertEqual(install?.displayCommand, "curl -fsSL https://claude.ai/install.sh | bash")
            XCTAssertEqual(install?.arguments.first, "-l")
            XCTAssertTrue(install?.arguments.last?.hasSuffix("| bash") ?? false)
            XCTAssertNil(model.fixLaunch(for: .chooseExecutable))
        }
    }
}

final class EnvironmentGatingTests: XCTestCase {
    var runner = FakeRunner()

    func testStartingASessionWithoutClaudeAsksForSetup() async throws {
        let (model, project, existing) = try await MainActor.run { () -> (AppModel, UUID, UUID) in
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            let s = Session(projectID: p, claudeSessionID: "abc", hasConversation: true, name: "old", workingDirectory: "/code")
            try state.workspace.addSession(s)
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                                 locateClaude: { _ in nil }, shell: "/bin/zsh", home: "/Users/tim")
            return (model, p, s.id)
        }
        await model.checkEnvironment()
        await MainActor.run {
            let request = NewSessionRequest(projectID: project, folderID: nil, name: "x", role: .code, prompt: "hi", model: nil, permissionMode: .auto)
            XCTAssertNil(model.createSession(request))
            XCTAssertTrue(model.setupRequested)
            XCTAssertEqual(model.workspace.sessions.count, 1, "nothing half-created")
            model.setupRequested = false
            model.resume(existing)
            XCTAssertTrue(model.setupRequested)
            XCTAssertFalse(model.isRunning(existing))
            model.updateMenuFlags()
            XCTAssertFalse(model.menuFlags.canRunSessions)
        }
    }
}
