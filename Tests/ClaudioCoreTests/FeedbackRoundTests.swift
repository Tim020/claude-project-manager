import XCTest
@testable import ClaudioCore

final class UsageCommandTests: XCTestCase {
    let output = """
    Total cost:            $0.0000
    Total duration (API):  0s
    Usage:                 0 input, 0 output, 0 cache read, 0 cache write
    Current session: 56% used · resets 3:10pm (Europe/London)
    Current week (all models): 7% used · resets Sep 29, 9am (Europe/London)
    Current week (Sonnet only): 2% used
    """

    func testParsesPlanUsageFromTheUsageCommand() throws {
        let now = Date(timeIntervalSince1970: 1_790_340_000)
        let usage = try XCTUnwrap(UsageSnapshot.parseUsageCommand(output, updatedAt: now))
        XCTAssertEqual(usage.fiveHour?.usedPercentage, 56)
        XCTAssertEqual(usage.fiveHour?.resetLabel(now: now), "resets 3:10pm (Europe/London)")
        XCTAssertEqual(usage.sevenDay?.usedPercentage, 7)
        XCTAssertEqual(usage.sevenDay?.resetLabel(now: now), "resets Sep 29, 9am (Europe/London)")
        XCTAssertEqual(usage.updatedAt, now)
    }

    func testNoPlanLinesMeansNoSnapshot() {
        XCTAssertNil(UsageSnapshot.parseUsageCommand("Total cost: $0.0000\n", updatedAt: Date()))
    }

    func testUsageCommand() {
        let commands = AgentCommands(claudeExecutable: "/usr/local/bin/claude", shell: "/bin/zsh", hookEventsPath: "/tmp/h")
        let command = commands.usage()
        XCTAssertEqual(command.claudeArguments, ["-p", "/usage", "--no-session-persistence"])
        XCTAssertEqual(command.arguments.first, "-c", "no login shell for a periodic check")
    }
}

final class SessionStatusCaptureTests: XCTestCase {
    let input = #"""
    {"session_id":"x","rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1790352000}},
     "context_window":{"total_input_tokens":84000,"total_output_tokens":1200,"context_window_size":200000,"used_percentage":42,"remaining_percentage":58}}
    """#

    func testParsesContextWindow() throws {
        let context = try XCTUnwrap(ContextUsage.parse(Data(input.utf8)))
        XCTAssertEqual(context, ContextUsage(usedPercentage: 42, windowSize: 200_000, inputTokens: 84_000))
        XCTAssertEqual(context.label, "42%")
        XCTAssertEqual(context.detail, "84k of 200k tokens")
        XCTAssertNil(ContextUsage.parse(Data(#"{"context_window":{"used_percentage":null}}"#.utf8)))
    }

    func testCaptureWritesPerSessionStatusAndSharedUsage() throws {
        let dir = try makeTemporaryDirectory()
        let appID = UUID()
        let capture = StatusLineCapture(statusDirectory: dir.appendingPathComponent("status").path,
                                        usagePath: dir.appendingPathComponent("usage.json").path, userStatusLine: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", capture.command(for: appID)]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let status = try Data(contentsOf: dir.appendingPathComponent("status/\(appID.uuidString).json"))
        XCTAssertEqual(ContextUsage.parse(status)?.usedPercentage, 42)
        let usage = try Data(contentsOf: dir.appendingPathComponent("usage.json"))
        XCTAssertEqual(UsageSnapshot.parse(usage, updatedAt: Date())?.fiveHour?.usedPercentage, 40)
    }

    func testModelReadsContextPerSession() throws {
        try MainActor.assumeIsolated {
            let dir = try makeTemporaryDirectory()
            let status = dir.appendingPathComponent("status")
            try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true)
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            let s = Session(projectID: p, name: "s", workingDirectory: "/code")
            try state.workspace.addSession(s)
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: dir), hookEventsURL: dir.appendingPathComponent("h.log"),
                                 usageURL: dir.appendingPathComponent("usage.json"), statusDirectory: status,
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            XCTAssertNil(model.context(for: s.id))
            try input.write(to: status.appendingPathComponent("\(s.id.uuidString).json"), atomically: true, encoding: .utf8)
            model.pollUsage()
            XCTAssertEqual(model.context(for: s.id)?.usedPercentage, 42)
        }
    }

    func testModelRefreshesUsageFromTheUsageCommand() async throws {
        let runner = FakeRunner()
        runner.usageOutput = "Current session: 12% used · resets 5pm\nCurrent week (all models): 3% used\n"
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        await model.refreshUsage()
        await MainActor.run {
            XCTAssertEqual(model.usage?.fiveHour?.usedPercentage, 12)
            XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 3)
        }
    }
}

final class GlobalTabsTests: XCTestCase {
    func testTabsSpanFoldersInOpenOrder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let f = try ws.createFolder(in: p, named: "F")
        let a = Session(projectID: p, name: "a", workingDirectory: "/code")
        let b = Session(projectID: p, name: "b", workingDirectory: "/code")
        try ws.addSession(a, toFolder: f)
        try ws.addSession(b)
        ws.openTab(b.id)
        ws.openTab(a.id)
        ws.openTab(b.id)
        XCTAssertEqual(ws.openTabSessions.map(\.name), ["b", "a"], "tab order is the order they were opened")
        ws.closeOtherTabs(keeping: a.id)
        XCTAssertEqual(ws.openTabSessions.map(\.name), ["a"], "Close Others closes the pane's tabs from every folder")
    }

    func testModelTabsAcrossFoldersAndSplit() throws {
        try MainActor.assumeIsolated {
            let model = AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            let p = model.addProject(path: "/code")
            let f = try XCTUnwrap(model.createFolder(in: p))
            var settings = model.settings
            settings.useBackgroundAgents = false
            model.updateSettings(settings)
            let inFolder = try XCTUnwrap(model.createSession(NewSessionRequest(projectID: p, folderID: f, name: "in folder", role: .code, prompt: "", model: nil, permissionMode: .auto)))
            let loose = try XCTUnwrap(model.createSession(NewSessionRequest(projectID: p, folderID: nil, name: "loose", role: .code, prompt: "", model: nil, permissionMode: .auto)))
            XCTAssertEqual(model.tabs.map(\.id), [inFolder, loose])
            XCTAssertTrue(model.tabsSpanFolders)
            model.splitTab(loose, to: .right, of: model.panes.focusedGroupID)
            XCTAssertEqual(model.visibleSessionIDs, [inFolder, loose])
            model.closeTab(loose)
            XCTAssertEqual(model.selectedSessionID, inFolder)
            XCTAssertFalse(model.panes.isSplit)
        }
    }
}

final class RoleTests: XCTestCase {
    func testRolesAreFreeformAndInferredFromTheList() {
        XCTAssertEqual(SessionRole.code.label, "CODE")
        XCTAssertEqual(SessionRole.none.label, "")
        XCTAssertEqual(SessionRole.infer(fromName: "pr review inline 1427", roles: ["Code", "Review"]), .review)
        XCTAssertEqual(SessionRole.infer(fromName: "db migration", roles: ["Code", "Migration"]), SessionRole("Migration"))
        XCTAssertEqual(SessionRole.infer(fromName: "fix the bug", roles: ["Code", "Review"]), .code, "falls back to Code when listed")
        XCTAssertEqual(SessionRole.infer(fromName: "fix the bug", roles: ["Review"]), .none)
    }

    func testLegacyRoleValuesDecode() throws {
        func decode(_ raw: String) throws -> SessionRole {
            try JSONDecoder().decode(SessionRole.self, from: Data("\"\(raw)\"".utf8))
        }
        XCTAssertEqual(try decode("code"), .code)
        XCTAssertEqual(try decode("review"), .review)
        XCTAssertEqual(try decode("other"), .none)
        XCTAssertEqual(try decode("Migration"), SessionRole("Migration"))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(SessionRole("Migration")), as: UTF8.self), "\"Migration\"")
    }

    func testEditableRoleListInSettings() throws {
        XCTAssertEqual(AppSettings().roles, ["Code", "Review", "Research"])
        var settings = AppSettings()
        settings.roles = ["Code", "Migration"]
        let decoded = try JSONFileStore.decoder.decode(AppSettings.self, from: JSONFileStore.encoder.encode(settings))
        XCTAssertEqual(decoded.roles, ["Code", "Migration"])
        XCTAssertEqual(AppSettings.cleanRoles([" Code ", "", "code", "Ops"]), ["Code", "Ops"], "trimmed, no blanks or duplicates")
    }
}

final class PermissionDefaultTests: XCTestCase {
    func testNewDefaultIsAuto() {
        XCTAssertEqual(AppSettings().defaultPermissionMode, .auto)
    }

    func testOldSavedDefaultMigratesToAutoButExplicitChoicesStay() throws {
        let old = #"{"version":1,"workspace":{"projects":[],"sessions":[]},"settings":{"defaultPermissionMode":"default"}}"#
        XCTAssertEqual(try JSONFileStore.decoder.decode(PersistedState.self, from: Data(old.utf8)).settings.defaultPermissionMode, .auto)
        let chosen = #"{"version":1,"workspace":{"projects":[],"sessions":[]},"settings":{"defaultPermissionMode":"plan"}}"#
        XCTAssertEqual(try JSONFileStore.decoder.decode(PersistedState.self, from: Data(chosen.utf8)).settings.defaultPermissionMode, .plan)
        let current = #"{"version":2,"workspace":{"projects":[],"sessions":[]},"settings":{"defaultPermissionMode":"default"}}"#
        XCTAssertEqual(try JSONFileStore.decoder.decode(PersistedState.self, from: Data(current.utf8)).settings.defaultPermissionMode, .standard,
                       "an explicit Ask choice made after the change is kept")
    }
}
