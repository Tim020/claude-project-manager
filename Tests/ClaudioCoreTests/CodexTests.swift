import XCTest
@testable import ClaudioCore

final class CodexTests: XCTestCase {
    private let threadID = "12345678-1234-1234-1234-123456789abc"

    private func session() -> Session {
        var session = Session(projectID: UUID(), name: "Codex work", workingDirectory: "/tmp/project with 'quotes'")
        session.provider = .codex
        return session
    }

    func testOldStateDefaultsToClaudeAndNewFieldsRoundTrip() throws {
        let old = Session(projectID: UUID(), name: "Existing Claude chat", workingDirectory: "/code/project")
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        for key in ["provider", "codexSessionID", "codexPermissions"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.provider, .claude)
        XCTAssertNil(decoded.codexSessionID)
        XCTAssertEqual(decoded.codexPermissions, .configured)
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(oldSettings.defaultProvider, .claude)
        XCTAssertEqual(oldSettings.defaultCodexPermissions, .configured)

        var codex = session()
        codex.codexSessionID = threadID
        codex.codexPermissions = .workspaceWrite
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: encoder.encode(codex)), codex)
        var settings = AppSettings()
        settings.defaultProvider = .codex
        settings.codexPath = "/custom/codex"
        settings.defaultCodexModel = "custom-model"
        settings.defaultCodexPermissions = .readOnly
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoder.encode(settings)), settings)
    }

    func testLocatorPrefersPathAndHonorsAnExplicitChoice() {
        let executablePaths = ["/npm/bin/codex", "/home/test/.local/bin/codex"]
        let exists: (String) -> Bool = executablePaths.contains
        XCTAssertEqual(CodexExecutableLocator.locate(pathVariable: "/npm/bin", home: "/home/test", isExecutable: exists), "/npm/bin/codex")
        XCTAssertEqual(CodexExecutableLocator.locate(pathVariable: "", home: "/home/test", isExecutable: exists), "/home/test/.local/bin/codex")
        XCTAssertNil(CodexExecutableLocator.locate(override: "/broken/codex", pathVariable: "/npm/bin", isExecutable: exists))
    }

    func testNewLaunchKeepsCodexConfigurationAndNeverPassesClaudeFlags() {
        let session = session()
        let launch = CodexLaunch.make(session: session, executable: "/tools/codex", shell: "/bin/sh",
                                      prompt: "- [ ] fix $(touch /tmp/unwanted); `exit`", eventsPath: "/tmp/events with spaces")
        XCTAssertEqual(Array(launch.claudeArguments.suffix(2)), ["--", "- [ ] fix $(touch /tmp/unwanted); `exit`"])
        XCTAssertEqual(launch.environment["CLAUDIO_SESSION_ID"], session.id.uuidString)
        XCTAssertEqual(launch.environment["CLAUDIO_CODEX_EVENTS_PATH"], "/tmp/events with spaces")
        XCTAssertTrue(launch.claudeArguments.contains("--no-daemon"))
        for forbidden in ["--settings", "--session-id", "--permission-mode", "--bg", "--plugin-dir", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "--sandbox", "--ask-for-approval"] {
            XCTAssertFalse(launch.claudeArguments.contains(forbidden), forbidden)
        }
        XCTAssertEqual(launch.displayCommand, "codex")
    }

    func testResumeUsesExactIDAndExplicitSandbox() {
        var session = session()
        session.codexSessionID = threadID
        session.codexPermissions = .workspaceWrite
        session.model = "custom-model"
        let launch = CodexLaunch.make(session: session, executable: "/tools/codex", shell: "/bin/sh", prompt: nil, eventsPath: "/tmp/events")
        XCTAssertEqual(Array(launch.claudeArguments.prefix(2)), ["resume", threadID])
        XCTAssertTrue(launch.claudeArguments.contains("workspace-write"))
        XCTAssertTrue(launch.claudeArguments.contains("on-request"))
        XCTAssertTrue(launch.claudeArguments.contains("custom-model"))
        XCTAssertFalse(launch.claudeArguments.contains("--last"))
    }

    func testLaunchQuotesEveryArgumentWhenExecutedByTheShell() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("project with 'quotes'", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("fake codex")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\"\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var session = session()
        session.workingDirectory = directory.path
        let prompt = "- fix 'quotes'; $(printf unwanted) `printf unwanted`\nand a second line"
        let launch = CodexLaunch.make(session: session, executable: binary.path, shell: "/bin/sh", prompt: prompt,
                                      eventsPath: directory.appendingPathComponent("events.log").path)
        let result = await ProcessCommandRunner().run(launch)
        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        XCTAssertEqual(result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init), launch.claudeArguments)
    }

    func testRecordedCodexHooks() throws {
        // Captured from codex-cli 0.162.0-alpha.17.2 with a test-only key and
        // an unreachable localhost provider; only local paths were scrubbed.
        let text = try String(contentsOf: Fixtures.url("codex-hooks.log"))
        let events = text.split(separator: "\n").compactMap { HookEventParser.parse(String($0)) }
        XCTAssertEqual(events.map(\.name), [.sessionStart, .userPromptSubmit, .other("Interrupt"), .sessionEnd])
        var session = session()
        for event in events { CodexHookReducer.apply(event, to: &session, now: Date()) }
        XCTAssertNotNil(session.codexSessionID)
        XCTAssertNil(session.claudeSessionID)
        XCTAssertEqual(session.status, .completed)
    }

    func testStopBeforeTerminalCreationAndLateHooksDoNotReviveSession() throws {
        try MainActor.assumeIsolated {
            let directory = try makeTemporaryDirectory()
            let store = MemoryStore()
            let projectID = store.state.workspace.addProject(path: "/tmp/codex-project")
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: directory),
                                 hookEventsURL: directory.appendingPathComponent("hooks.log"),
                                 locateCodex: { _ in "/tools/codex" })
            var request = NewSessionRequest(projectID: projectID, folderID: nil, name: "Codex", prompt: "", model: nil, permissionMode: .standard)
            request.provider = .codex
            let id = try XCTUnwrap(model.createSession(request))
            model.stop(id)
            XCTAssertFalse(model.isRunning(id))
            XCTAssertNil(model.takePendingLaunch(id))
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertNil(model.workspace.session(id)?.needsAction)
            let event = "\(id)\t" + #"{"session_id":"\#(threadID)","hook_event_name":"UserPromptSubmit"}"# + "\n"
            try event.write(to: directory.appendingPathComponent("codex-hook-events.log"), atomically: false, encoding: .utf8)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
        }
    }

    func testHookRoundTripThroughRealShellAndReducer() async throws {
        var session = session()
        let directory = try makeTemporaryDirectory().appendingPathComponent("events with 'quotes'", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("codex.log")
        let event = #"{"session_id":"\#(threadID)","hook_event_name":"UserPromptSubmit","prompt":"test"}"#
        let command = "printf '%s' \(ShellQuote.quote(event)) | (\(CodexLaunch.hookCommand))"
        var launch = TerminalLaunch.script(command, workingDirectory: directory.path, shell: "/bin/sh")
        launch.environment["CLAUDIO_SESSION_ID"] = session.id.uuidString
        launch.environment["CLAUDIO_CODEX_EVENTS_PATH"] = log.path
        let result = await ProcessCommandRunner().run(launch)
        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        var tailer = HookEventTailer(url: log)
        let parsed = try XCTUnwrap(tailer.readNew().first)
        XCTAssertEqual(parsed.appSessionID, session.id)
        CodexHookReducer.apply(parsed, to: &session, now: Date())
        XCTAssertEqual(session.codexSessionID, threadID)
        XCTAssertNil(session.claudeSessionID)
        XCTAssertTrue(session.hasConversation)
        XCTAssertEqual(session.status, .working)
        XCTAssertTrue(tailer.readNew().isEmpty)
    }

    func testStatusTransitionsIgnoreMalformedAndLateEvents() throws {
        var session = session()
        func apply(_ name: String, extra: String = "") throws {
            let line = "\(session.id)\t" + #"{"session_id":"\#(threadID)","hook_event_name":"\#(name)"\#(extra)}"#
            CodexHookReducer.apply(try XCTUnwrap(HookEventParser.parse(line)), to: &session, now: Date())
        }
        try apply("UserPromptSubmit")
        try apply("PermissionRequest")
        XCTAssertEqual(session.status, .awaitingInput)
        try apply("PostToolUse")
        XCTAssertEqual(session.status, .working)
        XCTAssertNil(session.needsAction)
        try apply("Stop", extra: #", "last_assistant_message":"All done.""#)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.summary, "All done.")
        try apply("Interrupt")
        XCTAssertEqual(session.status, .awaitingInput)
        try apply("SessionEnd")
        XCTAssertEqual(session.status, .completed)
        let original = session
        var late = HookEvent(appSessionID: session.id, name: .userPromptSubmit)
        late.claudeSessionID = UUID().uuidString
        CodexHookReducer.apply(late, to: &session, now: Date())
        XCTAssertEqual(session, original)
        late.claudeSessionID = "invalid"
        CodexHookReducer.apply(late, to: &session, now: Date())
        XCTAssertEqual(session, original)
    }

    func testCodexCreationWithoutClaudeAndExactResumeAfterRestart() async throws {
        try await MainActor.run {
            let directory = try makeTemporaryDirectory()
            let store = MemoryStore()
            let projectID = store.state.workspace.addProject(path: "/tmp/codex-project")
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: directory),
                                 hookEventsURL: directory.appendingPathComponent("hooks.log"), runner: FakeRunner(),
                                 locateClaude: { _ in nil }, locateCodex: { _ in "/tools/codex" }, locateGitHubCLI: { nil })
            var request = NewSessionRequest(projectID: projectID, folderID: nil, name: "Codex", prompt: "Review", model: nil, permissionMode: .bypassPermissions)
            request.provider = .codex
            let id = try XCTUnwrap(model.createSession(request))
            XCTAssertEqual(model.workspace.session(id)?.provider, .codex)
            XCTAssertNil(model.workspace.session(id)?.agentID)
            XCTAssertNil(model.workspace.session(id)?.claudeSessionID)
            XCTAssertFalse(try XCTUnwrap(model.takePendingLaunch(id)).claudeArguments.contains("--permission-mode"))
            let event = "\(id)\t" + #"{"session_id":"\#(threadID)","hook_event_name":"SessionStart","source":"startup"}"# + "\n"
            try event.write(to: directory.appendingPathComponent("codex-hook-events.log"), atomically: false, encoding: .utf8)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(id)?.codexSessionID, threadID)
            model.terminalExited(id, exitCode: 0)
            // A crash, or a state saved before stopping, can retain a wait.
            store.state.workspace.updateSession(id) { $0.status = .awaitingInput; $0.needsAction = "Old approval" }
            let restored = AppModel(store: store, discovery: SessionDiscovery(claudeHome: directory),
                                    hookEventsURL: directory.appendingPathComponent("hooks.log"), runner: FakeRunner(),
                                    locateClaude: { _ in nil }, locateCodex: { _ in "/tools/codex" }, locateGitHubCLI: { nil })
            XCTAssertEqual(restored.workspace.session(id)?.status, .completed)
            XCTAssertNil(restored.workspace.session(id)?.needsAction)
            restored.resume(id)
            XCTAssertEqual(Array(try XCTUnwrap(restored.takePendingLaunch(id)).claudeArguments.prefix(2)), ["resume", threadID])
        }
    }

    func testMissingCodexDoesNotCreateSessionAndUnknownIDUsesPicker() throws {
        try MainActor.assumeIsolated {
            let directory = try makeTemporaryDirectory()
            let store = MemoryStore()
            let projectID = store.state.workspace.addProject(path: "/tmp/codex-project")
            let missing = AppModel(store: store, discovery: SessionDiscovery(claudeHome: directory), hookEventsURL: directory.appendingPathComponent("hooks"), locateCodex: { _ in nil })
            var request = NewSessionRequest(projectID: projectID, folderID: nil, name: "Codex", prompt: "", model: nil, permissionMode: .standard)
            request.provider = .codex
            XCTAssertNil(missing.createSession(request))
            XCTAssertTrue(missing.workspace.sessions.isEmpty)
            XCTAssertTrue(missing.errorMessage?.contains("Codex CLI not found") == true)

            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: directory), hookEventsURL: directory.appendingPathComponent("hooks"), locateCodex: { _ in "/tools/codex" })
            let id = try XCTUnwrap(model.createSession(request))
            model.terminalExited(id, exitCode: 0)
            model.resume(id)
            let launch = try XCTUnwrap(model.takePendingLaunch(id))
            XCTAssertEqual(launch.claudeArguments.first, "resume")
            XCTAssertFalse(launch.claudeArguments.contains("--last"))
        }
    }
}
