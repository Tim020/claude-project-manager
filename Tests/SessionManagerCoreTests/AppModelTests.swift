import XCTest
@testable import SessionManagerCore

final class FakeProcess: AgentProcess {
    var onEvent: ((StreamEvent) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var isRunning = false
    var sent: [String] = []
    var terminated = false
    var startError: Error?
    let configuration: ClaudeLaunchConfiguration

    init(configuration: ClaudeLaunchConfiguration) {
        self.configuration = configuration
    }

    func start() throws {
        if let startError { throw startError }
        isRunning = true
    }

    func send(_ line: String) throws {
        guard isRunning else { throw AgentProcessError.notRunning }
        sent.append(line)
    }

    func terminate() {
        terminated = true
        exit(143)
    }

    func emit(_ event: StreamEvent) { onEvent?(event) }

    func exit(_ code: Int32, stderr: String = "") {
        guard isRunning else { return }
        isRunning = false
        onExit?(code, stderr)
    }

    var sentPrompts: [String] {
        sent.compactMap { line in
            (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?["message"]?["content"]?.stringValue
        }
    }
}

final class MemoryStore: StateStore {
    var state = PersistedState()
    var saves = 0
    func load() throws -> PersistedState { state }
    func save(_ state: PersistedState) throws {
        self.state = state
        saves += 1
    }
}

/// Test bodies run via `MainActor.assumeIsolated`: XCTest runs tests on the
/// main thread, and a `@MainActor` test class breaks test discovery on Linux.
final class AppModelTests: XCTestCase {
    let projectPath = "/Users/tim/Documents/Code/DigiScript"
    var store = MemoryStore()
    var processes: [FakeProcess] = []
    var claudePath: String? = "/usr/local/bin/claude"
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    private func makeModel() throws -> AppModel {
        AppModel(
            store: store,
            discovery: SessionDiscovery(claudeHome: try Fixtures.url("claude-home")),
            processFactory: { [unowned self] config in
                let process = FakeProcess(configuration: config)
                self.processes.append(process)
                return process
            },
            locateClaude: { [unowned self] _ in self.claudePath },
            now: { [unowned self] in self.clock },
            home: "/Users/tim")
    }

    @MainActor
    private func request(_ model: AppModel, project: UUID, folder: UUID? = nil, prompt: String = "Fix the storage bug") -> NewSessionRequest {
        NewSessionRequest(projectID: project, folderID: folder, name: "storage fix", role: .code, prompt: prompt, model: nil, permissionMode: .acceptEdits)
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

    func testStateIsLoadedFromStore() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            state.workspace.addProject(path: "/code/x")
            state.settings.layout = .split
            store.state = state
            let model = try makeModel()
            XCTAssertEqual(model.workspace.projects.map(\.name), ["x"])
            XCTAssertEqual(model.settings.layout, .split)
        }
    }

    func testRemoveProjectStopsItsProcessesAndClearsSelection() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(model, project: p)))
            model.removeProject(p)
            XCTAssertTrue(processes[0].terminated)
            XCTAssertNil(model.selectedSessionID)
            XCTAssertTrue(model.workspace.projects.isEmpty)
            XCTAssertNil(model.workspace.session(id))
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
            let sessions = model.workspace.sessions(in: .unfiled(projectID: p))
            for s in sessions { model.moveSession(s.id, to: .folder(f)) }
            XCTAssertEqual(model.workspace.sessions(in: .folder(f)).count, 2)
            model.archiveCompleted(in: .folder(f))
            // One is completed, the other awaits input.
            XCTAssertEqual(model.workspace.sessions(in: .folder(f)).map(\.name), ["pr review inline 1427"])
        }
    }

    // MARK: Sessions

    func testCreateSessionStartsProcessSendsPromptAndSelects() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            let id = try XCTUnwrap(model.createSession(request(model, project: p, folder: f)))

            let session = try XCTUnwrap(model.workspace.session(id))
            XCTAssertEqual(model.selectedSessionID, id)
            XCTAssertEqual(model.workspace.group(of: id), .folder(f))
            XCTAssertEqual(session.status, .working)
            XCTAssertEqual(session.workingDirectory, "/code/app")
            XCTAssertNotNil(session.claudeSessionID)

            let process = try XCTUnwrap(processes.first)
            XCTAssertEqual(process.configuration.resume, false)
            XCTAssertEqual(process.configuration.claudeSessionID, session.claudeSessionID)
            XCTAssertEqual(process.configuration.executable, "/usr/local/bin/claude")
            XCTAssertEqual(process.sentPrompts, ["Fix the storage bug"])
            XCTAssertEqual(model.activity(for: id).transcript.lines.map(\.text), ["Fix the storage bug"])
            XCTAssertTrue(model.isRunning(id))
        }
    }

    func testCreateSessionWithoutPromptDoesNotLaunch() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(model, project: p, prompt: "  ")))
            XCTAssertTrue(processes.isEmpty)
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
        }
    }

    func testBlankSessionNameFallsBackToPrompt() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            var req = request(model, project: p, prompt: "Review PR 1422 and post inline comments")
            req.name = ""
            let id = try XCTUnwrap(model.createSession(req))
            XCTAssertEqual(model.workspace.session(id)?.name, "Review PR 1422 and post inline comments")
            XCTAssertEqual(model.workspace.session(id)?.role, .code, "explicit role wins")
        }
    }

    func testEventsFromProcessUpdateSessionAndTranscript() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(model, project: p)))
            let process = processes[0]
            for event in try Fixtures.lines("stream-basic.jsonl").compactMap(StreamEventParser.parse) {
                process.emit(event)
            }
            let session = try XCTUnwrap(model.workspace.session(id))
            XCTAssertEqual(session.status, .awaitingInput)
            XCTAssertEqual(session.model, "claude-sonnet-5")
            XCTAssertTrue(session.hasConversation)
            XCTAssertEqual(model.activity(for: id).transcript.lines.map(\.kind), [.prompt, .tool, .assistant])
            XCTAssertEqual(model.awaitingInputCount, 1)
            XCTAssertEqual(store.state.workspace.session(id)?.status, .awaitingInput, "status changes are persisted")
        }
    }

    func testFollowUpMessageReusesRunningProcess() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(model, project: p)))
            processes[0].emit(.result(ResultInfo(isError: false, subtype: "success", text: "Which option?", sessionID: nil, costUSD: nil, permissionDenials: 0)))
            model.send("Option B", to: id)
            XCTAssertEqual(processes.count, 1)
            XCTAssertEqual(processes[0].sentPrompts, ["Fix the storage bug", "Option B"])
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
        }
    }

    func testMessagingImportedSessionResumesIt() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let imported = model.workspace.sessions(in: .unfiled(projectID: p))[1]
            model.send("Post it", to: imported.id)
            let process = try XCTUnwrap(processes.first)
            XCTAssertTrue(process.configuration.resume)
            XCTAssertEqual(process.configuration.claudeSessionID, "bbbbbbbb-0000-0000-0000-000000000002")
            XCTAssertEqual(process.configuration.workingDirectory, projectPath)
        }
    }

    func testProcessExitAllowsRelaunchWithResume() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(model, project: p)))
            processes[0].emit(.initialized(sessionID: model.workspace.session(id)!.claudeSessionID!, model: nil, cwd: nil))
            processes[0].exit(1, stderr: "boom\nAPI Error: overloaded")
            XCTAssertFalse(model.isRunning(id))
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertEqual(model.activity(for: id).transcript.lines.last?.text, "API Error: overloaded")

            model.send("try again", to: id)
            XCTAssertEqual(processes.count, 2)
            XCTAssertTrue(processes[1].configuration.resume)
        }
    }

    func testMissingClaudeReportsErrorWithoutChangingStatus() throws {
        try MainActor.assumeIsolated {
            claudePath = nil
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(model, project: p)))
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(processes.isEmpty)
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
        }
    }

    func testStartFailureReportsError() throws {
        try MainActor.assumeIsolated {
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try Fixtures.url("claude-home")),
                                 processFactory: { config in
                                     let process = FakeProcess(configuration: config)
                                     process.startError = AgentProcessError.executableNotFound("/x")
                                     return process
                                 },
                                 locateClaude: { _ in "/x" }, now: { Date() }, home: "/")
            let p = model.addProject(path: "/code/app")
            let id = model.createSession(NewSessionRequest(projectID: p, folderID: nil, name: "n", role: .code, prompt: "go", model: nil, permissionMode: .auto))
            XCTAssertNotNil(id)
            XCTAssertEqual(model.errorMessage, "Claude Code was not found at /x.")
            XCTAssertFalse(model.isRunning(id!))
        }
    }

    func testInterruptSendsControlRequest() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let id = try XCTUnwrap(model.createSession(request(model, project: p)))
            model.interrupt(id)
            let last = try JSONDecoder().decode(JSONValue.self, from: Data(processes[0].sent.last!.utf8))
            XCTAssertEqual(last["type"], .string("control_request"))
        }
    }

    func testDeleteSessionTerminatesAndMovesSelectionToSibling() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            let f = try XCTUnwrap(model.createFolder(in: p))
            let first = try XCTUnwrap(model.createSession(request(model, project: p, folder: f)))
            let second = try XCTUnwrap(model.createSession(request(model, project: p, folder: f)))
            XCTAssertEqual(model.selectedSessionID, second)
            model.deleteSession(second)
            XCTAssertTrue(processes[1].terminated)
            XCTAssertNil(model.workspace.session(second))
            XCTAssertEqual(model.selectedSessionID, first)
        }
    }

    // MARK: Selection & presentation

    func testSelectingImportedSessionLoadsHistory() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let s = model.workspace.sessions(in: .unfiled(projectID: p))[0]
            model.select(s.id)
            XCTAssertEqual(model.activity(for: s.id).transcript.lines.map(\.kind), [.prompt, .tool, .assistant])
        }
    }

    func testTabsAreSelectedSessionsFolderSiblings() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let f = try XCTUnwrap(model.createFolder(in: p))
            let unfiled = model.workspace.sessions(in: .unfiled(projectID: p))
            model.moveSession(unfiled[0].id, to: .folder(f))
            model.moveSession(unfiled[1].id, to: .folder(f))
            model.select(unfiled[1].id)
            XCTAssertEqual(model.tabs.map(\.id), [unfiled[0].id, unfiled[1].id])
            XCTAssertEqual(model.breadcrumb, Breadcrumb(project: "DigiScript", folder: "New Folder", session: "pr review inline 1427"))
            // Split view panes load every sibling's history.
            XCTAssertFalse(model.activity(for: unfiled[0].id).transcript.lines.isEmpty)
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

    func testRefreshPicksUpNewDiskStateButSkipsLiveSessions() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            let s = model.workspace.sessions(in: .unfiled(projectID: p))[1]
            model.send("go", to: s.id)
            model.refreshAll()
            XCTAssertEqual(model.workspace.session(s.id)?.status, .working)
        }
    }

    func testShutdownTerminatesEverything() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let p = model.addProject(path: "/code/app")
            _ = model.createSession(request(model, project: p))
            _ = model.createSession(request(model, project: p))
            model.shutdown()
            XCTAssertTrue(processes.allSatisfy(\.terminated))
        }
    }
}
