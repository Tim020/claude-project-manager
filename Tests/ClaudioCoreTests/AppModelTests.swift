import XCTest
@testable import ClaudioCore

final class MemoryStore: StateStore {
    var state = PersistedState()
    var saves = 0
    func load() throws -> PersistedState { state }
    func save(_ state: PersistedState) throws {
        self.state = state
        saves += 1
    }
}

final class FakeTerminals: TerminalControlling {
    var terminated: [UUID] = []
    func terminate(_ sessionID: UUID) { terminated.append(sessionID) }
}

/// Test bodies run via `MainActor.assumeIsolated`: XCTest runs tests on the
/// main thread, and a `@MainActor` test class breaks test discovery on Linux.
final class AppModelTests: XCTestCase {
    let projectPath = "/Users/tim/Documents/Code/DigiScript"
    var store = MemoryStore()
    var terminals: FakeTerminals!
    var claudePath: String? = "/usr/local/bin/claude"
    var clock = Date(timeIntervalSince1970: 1_790_000_000)
    var hookLog: URL!

    @MainActor
    private func makeModel() throws -> AppModel {
        hookLog = try makeTemporaryDirectory().appendingPathComponent("hook-events.log")
        let model = AppModel(
            store: store,
            discovery: SessionDiscovery(claudeHome: try Fixtures.url("claude-home")),
            hookEventsURL: hookLog,
            locateClaude: { [unowned self] _ in self.claudePath },
            shell: "/bin/zsh",
            now: { [unowned self] in self.clock },
            home: "/Users/tim")
        terminals = FakeTerminals()
        model.terminals = terminals
        // These tests cover direct terminal sessions; AgentModelTests cover `--bg`.
        var settings = model.settings
        settings.useBackgroundAgents = false
        model.updateSettings(settings)
        return model
    }

    @MainActor
    private func request(project: UUID, folder: UUID? = nil, prompt: String = "Fix the storage bug") -> NewSessionRequest {
        NewSessionRequest(projectID: project, folderID: folder, name: "storage fix", role: .code, prompt: prompt, model: nil, permissionMode: .standard)
    }

    private func appendHook(_ id: UUID, _ json: String) throws {
        let line = "\(id.uuidString)\t\(json)\n"
        if let handle = try? FileHandle(forWritingTo: hookLog) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: hookLog, atomically: false, encoding: .utf8)
        }
    }

    // MARK: Projects

    func testAddProjectImportsExistingSessionsAndSaves() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            XCTAssertEqual(model.workspace.sessions(in: .unfiled(projectID: p)).map(\.name), ["investigate issue correlation", "pr review inline 1427"])
            XCTAssertEqual(store.state.workspace, model.workspace)
            XCTAssertEqual(model.sidebar.first?.name, "DigiScript")
        }
    }

    func testStateIsLoadedFromStoreAndStaleWorkingIsReset() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code/x")
            try state.workspace.addSession(Session(projectID: p, name: "was running", workingDirectory: "/code/x", status: .working))
            state.settings.layout = .split
            store.state = state
            let model = try makeModel()
            XCTAssertEqual(model.workspace.projects.map(\.name), ["x"])
            XCTAssertEqual(model.settings.layout, .split)
            XCTAssertEqual(model.workspace.sessions.first?.status, .completed)
        }
    }

    func testRemoveProjectTerminatesItsTerminals() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(project: p)))
            model.removeProject(p)
            XCTAssertEqual(terminals.terminated, [id])
            XCTAssertNil(model.selectedSessionID)
            XCTAssertFalse(model.isRunning(id))
            XCTAssertTrue(model.workspace.projects.isEmpty)
        }
    }

    func testImportableProjectsExcludeOnesAlreadyAdded() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            XCTAssertEqual(Set(model.importableProjects(fileExists: { _ in true }).map(\.name)), ["DigiScript", "dreamteam-web"])
            model.addProject(path: projectPath)
            XCTAssertEqual(model.importableProjects(fileExists: { _ in true }).map(\.name), ["dreamteam-web"])
            XCTAssertEqual(model.importableProjects(fileExists: { _ in false }).count, 0, "only directories that still exist")
        }
    }

    func testImportProjectsAddsThemWithTheirSessions() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let added = model.importProjects(paths: [projectPath, "/Users/tim/Code/dreamteam-web", projectPath])
            XCTAssertEqual(added, 2)
            XCTAssertEqual(model.workspace.projects.map(\.name), ["DigiScript", "dreamteam-web"])
            XCTAssertEqual(model.workspace.sessions.count, 3)
            XCTAssertNotNil(model.selectedSessionID, "selects the newest imported session when nothing was selected")
            XCTAssertEqual(store.state.workspace.projects.count, 2)
        }
    }

    // MARK: Folders

    func testCreateFolderStartsInlineRenameAndCommitRenames() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            XCTAssertEqual(model.renamingFolderID, f)
            XCTAssertEqual(model.workspace.folder(f)?.name, "New Folder")
            model.commitRename(folderID: f, name: "Mic planner perf")
            XCTAssertNil(model.renamingFolderID)
            XCTAssertEqual(model.workspace.folder(f)?.name, "Mic planner perf")
        }
    }

    func testCommittingBlankRenameKeepsOldName() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            model.commitRename(folderID: f, name: "   ")
            XCTAssertEqual(model.workspace.folder(f)?.name, "New Folder")
            XCTAssertNil(model.renamingFolderID)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testDropSessionOnNewFolderTarget() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let session = model.workspace.sessions(in: .unfiled(projectID: p))[0]
            let f = try XCTUnwrap(model.createFolder(in: p, containing: session.id))
            XCTAssertEqual(model.workspace.group(of: session.id), .folder(f))
            XCTAssertEqual(model.renamingFolderID, f)
        }
    }

    func testMoveSessionAndArchiveCompleted() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let f = try XCTUnwrap(model.createFolder(in: p))
            for s in model.workspace.sessions(in: .unfiled(projectID: p)) { model.moveSession(s.id, to: .folder(f)) }
            XCTAssertEqual(model.workspace.sessions(in: .folder(f)).count, 2)
            model.archiveCompleted(in: .folder(f))
            XCTAssertEqual(model.workspace.sessions(in: .folder(f)).map(\.name), ["pr review inline 1427"])
        }
    }

    // MARK: Terminal lifecycle

    func testCreateSessionQueuesTerminalLaunchWithPrompt() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            let id = try XCTUnwrap(model.createSession(request(project: p, folder: f)))

            let session = try XCTUnwrap(model.workspace.session(id))
            XCTAssertEqual(model.selectedSessionID, id)
            XCTAssertEqual(model.workspace.group(of: id), .folder(f))
            XCTAssertEqual(session.workingDirectory, "/code/app")
            XCTAssertTrue(model.isRunning(id))
            XCTAssertEqual(session.status, .working, "started with a prompt")

            let launch = try XCTUnwrap(model.takePendingLaunch(id))
            XCTAssertEqual(launch.executable, "/bin/zsh")
            XCTAssertEqual(Array(launch.claudeArguments.prefix(3)), ["Fix the storage bug", "--session-id", session.claudeSessionID!])
            XCTAssertTrue(launch.claudeArguments.contains { $0.contains(self.hookLog.path) })
            XCTAssertNil(model.takePendingLaunch(id), "a launch is handed out once")
        }
    }

    func testCreateSessionWithoutPromptStillOpensTerminal() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            var req = request(project: p, prompt: " ")
            req.name = ""
            let id = try XCTUnwrap(model.createSession(req))
            XCTAssertEqual(model.workspace.session(id)?.name, "New session")
            XCTAssertEqual(model.workspace.session(id)?.status, .completed, "idle at an empty prompt")
            let launch = try XCTUnwrap(model.takePendingLaunch(id))
            XCTAssertEqual(launch.claudeArguments.first, "--session-id")
        }
    }

    func testBlankSessionNameFallsBackToPrompt() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            var req = request(project: p, prompt: "Review PR 1422 and post inline comments")
            req.name = ""
            let id = try XCTUnwrap(model.createSession(req))
            XCTAssertEqual(model.workspace.session(id)?.name, "Review PR 1422 and post inline comments")
        }
    }

    func testResumingImportedSessionUsesResume() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let imported = model.workspace.sessions(in: .unfiled(projectID: p))[1]
            XCTAssertFalse(model.isRunning(imported.id))
            XCTAssertTrue(model.start(imported.id))
            let launch = try XCTUnwrap(model.takePendingLaunch(imported.id))
            XCTAssertEqual(Array(launch.claudeArguments.prefix(2)), ["--resume", "bbbbbbbb-0000-0000-0000-000000000002"])
            XCTAssertTrue(launch.arguments[2].hasPrefix("cd '\(projectPath)' && exec "))
        }
    }

    func testStartingARunningSessionDoesNothing() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(project: p)))
            _ = model.takePendingLaunch(id)
            XCTAssertFalse(model.start(id))
            XCTAssertNil(model.takePendingLaunch(id))
        }
    }

    func testMissingClaudeReportsError() throws {
        try MainActor.assumeIsolated {
            claudePath = nil
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(project: p)))
            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.isRunning(id))
            XCTAssertNil(model.takePendingLaunch(id))
        }
    }

    func testTerminalExitStopsRunningAndRecordsExitCode() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(project: p)))
            try appendHook(id, #"{"hook_event_name":"UserPromptSubmit","session_id":"x"}"#)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(id)?.status, .working)

            model.terminalExited(id, exitCode: 1)
            XCTAssertFalse(model.isRunning(id))
            XCTAssertEqual(model.lastExitCode(id), 1)
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertTrue(model.workspace.session(id)!.hasConversation)

            XCTAssertTrue(model.start(id))
            XCTAssertNil(model.lastExitCode(id))
            XCTAssertEqual(model.takePendingLaunch(id)?.claudeArguments.first, "--resume")
        }
    }

    func testHookEventsUpdateStatusAndArePersisted() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(project: p)))
            let unknown = UUID()
            try appendHook(id, #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#)
            try appendHook(unknown, #"{"hook_event_name":"Stop"}"#)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(id)?.status, .awaitingInput)
            XCTAssertEqual(model.awaitingInputCount, 1)
            XCTAssertEqual(store.state.workspace.session(id)?.status, .awaitingInput)

            try appendHook(id, #"{"hook_event_name":"Stop","last_assistant_message":"Opened https://github.com/a/b/pull/7"}"#)
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertEqual(model.workspace.session(id)?.pullRequestURLs, ["https://github.com/a/b/pull/7"])
        }
    }

    func testHookLogContentFromBeforeLaunchIsIgnored() throws {
        try MainActor.assumeIsolated {
            hookLog = try makeTemporaryDirectory().appendingPathComponent("hook-events.log")
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code/x")
            let s = Session(projectID: p, name: "s", workingDirectory: "/code/x")
            try state.workspace.addSession(s)
            store.state = state
            try appendHook(s.id, #"{"hook_event_name":"UserPromptSubmit"}"#)
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try Fixtures.url("claude-home")),
                                 hookEventsURL: hookLog, locateClaude: { _ in "/c" }, shell: "/bin/sh", now: { Date() }, home: "/")
            model.pollHookEvents()
            XCTAssertEqual(model.workspace.session(s.id)?.status, .completed)
        }
    }

    func testDeleteSessionTerminatesAndMovesSelectionToSibling() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            let first = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            let second = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            XCTAssertEqual(model.selectedSessionID, second)
            model.deleteSession(second)
            XCTAssertEqual(terminals.terminated, [second])
            XCTAssertNil(model.workspace.session(second))
            XCTAssertEqual(model.selectedSessionID, first)
        }
    }

    func testStopAndShutdownTerminate() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let a = try XCTUnwrap(model.createSession(request(project: p)))
            let b = try XCTUnwrap(model.createSession(request(project: p)))
            model.stop(a)
            XCTAssertEqual(terminals.terminated, [a])
            model.shutdown()
            XCTAssertEqual(Set(terminals.terminated), [a, b])
        }
    }

    // MARK: Tabs

    func testSelectingOpensATabAndTabsAreOpenSiblings() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let f = try XCTUnwrap(model.createFolder(in: p))
            let unfiled = model.workspace.sessions(in: .unfiled(projectID: p))
            unfiled.forEach { model.moveSession($0.id, to: .folder(f)) }
            model.select(unfiled[0].id)
            XCTAssertEqual(model.tabs.map(\.id), [unfiled[0].id], "only opened sessions are tabs")
            model.select(unfiled[1].id)
            XCTAssertEqual(model.tabs.map(\.id), [unfiled[0].id, unfiled[1].id])
            XCTAssertEqual(store.state.workspace.openSessionIDs, Set(unfiled.map(\.id)))
        }
    }

    func testClosingSelectedTabSelectsNeighbourAndKeepsItRunning() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            let a = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            let b = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            let c = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            model.select(b)
            model.closeTab(b)
            XCTAssertEqual(model.selectedSessionID, a)
            XCTAssertEqual(model.tabs.map(\.id), [a, c])
            XCTAssertTrue(model.isRunning(b), "closing a tab doesn't stop the session")
            XCTAssertTrue(terminals.terminated.isEmpty)
        }
    }

    func testClosingLastTabClearsSelection() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let a = try XCTUnwrap(model.createSession(request(project: p)))
            model.closeTab(a)
            XCTAssertNil(model.selectedSessionID)
            XCTAssertEqual(model.tabs, [])
        }
    }

    func testClosingAnUnselectedTabKeepsSelection() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let a = try XCTUnwrap(model.createSession(request(project: p)))
            let b = try XCTUnwrap(model.createSession(request(project: p)))
            model.closeTab(a)
            XCTAssertEqual(model.selectedSessionID, b)
        }
    }

    func testCloseAndStop() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let a = try XCTUnwrap(model.createSession(request(project: p)))
            model.closeTab(a, stop: true)
            XCTAssertEqual(terminals.terminated, [a])
            XCTAssertFalse(model.workspace.isOpen(a))
        }
    }

    func testCloseOtherAndCompletedTabs() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            let a = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            let b = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            let c = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            model.closeOtherTabs(keeping: a)
            XCTAssertEqual(model.tabs.map(\.id), [a])
            XCTAssertEqual(model.selectedSessionID, a)
            [b, c].forEach { model.select($0) }
            model.closeCompletedTabs()
            XCTAssertEqual(model.tabs.count, 3, "sessions started with a prompt are working")
            model.terminalExited(b, exitCode: 0)
            model.closeCompletedTabs()
            XCTAssertEqual(model.tabs.map(\.id), [a, c])
        }
    }

    func testSplitIsOnlyForFoldersWithSeveralOpenTabs() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            _ = try XCTUnwrap(model.createSession(request(project: p)))
            _ = try XCTUnwrap(model.createSession(request(project: p)))
            model.setLayout(.split)
            XCTAssertFalse(model.canSplit, "Unfiled always uses tabs")

            let f = try XCTUnwrap(model.createFolder(in: p))
            let a = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            XCTAssertFalse(model.canSplit, "one open tab")
            let b = try XCTUnwrap(model.createSession(request(project: p, folder: f)))
            XCTAssertTrue(model.canSplit)
            XCTAssertEqual(model.splitPanes(capacity: 4).map(\.id), [a, b])
        }
    }

    func testSplitPanesPreferRecentlySelected() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            let ids = try (0..<5).map { _ in try XCTUnwrap(model.createSession(request(project: p, folder: f))) }
            model.select(ids[0])
            model.select(ids[3])
            XCTAssertEqual(model.splitPanes(capacity: 2).map(\.id), [ids[0], ids[3]])
        }
    }

    // MARK: Selection & presentation

    func testHistoryIsLoadedForImportedSessions() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let s = model.workspace.sessions(in: .unfiled(projectID: p))[0]
            model.select(s.id)
            return (model, s.id)
        }
        await model.loadHistory(id)
        await MainActor.run { XCTAssertEqual(model.history(for: id).map(\.kind), [.prompt, .tool, .assistant]) }
    }

    func testTabsAreSelectedSessionsFolderSiblings() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let f = try XCTUnwrap(model.createFolder(in: p))
            let unfiled = model.workspace.sessions(in: .unfiled(projectID: p))
            model.moveSession(unfiled[0].id, to: .folder(f))
            model.moveSession(unfiled[1].id, to: .folder(f))
            model.select(unfiled[0].id)
            model.select(unfiled[1].id)
            XCTAssertEqual(model.tabs.map(\.id), [unfiled[0].id, unfiled[1].id])
            XCTAssertEqual(model.breadcrumb, Breadcrumb(project: "DigiScript", folder: "New Folder", session: "pr review inline 1427"))
        }
    }

    func testFilterAffectsSidebar() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            model.addProject(path: projectPath)
            model.filterText = "review"
            XCTAssertEqual(model.sidebar.first?.folders.first?.sessions.map(\.name), ["pr review inline 1427"])
        }
    }

    func testLayoutAndSettingsArePersisted() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            model.setLayout(.split)
            XCTAssertEqual(store.state.settings.layout, .split)
            var settings = model.settings
            settings.defaultModel = "claude-opus-5-5"
            model.updateSettings(settings)
            XCTAssertEqual(store.state.settings.defaultModel, "claude-opus-5-5")
        }
    }

    func testRefreshSkipsRunningSessions() async throws {
        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let s = model.workspace.sessions(in: .unfiled(projectID: p))[1]
            model.start(s.id)
            try appendHook(s.id, #"{"hook_event_name":"UserPromptSubmit"}"#)
            model.pollHookEvents()
            return (model, s.id)
        }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.status, .working) }
    }
}
