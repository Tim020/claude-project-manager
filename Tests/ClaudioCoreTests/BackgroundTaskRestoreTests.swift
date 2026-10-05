import XCTest
@testable import ClaudioCore

/// A session's background tasks are saved, and checked against its agent's
/// job state at launch.
final class BackgroundTaskRestoreTests: XCTestCase {
    var store = MemoryStore()
    var claudeHome: URL!

    /// Recorded with 2.1.289, trimmed to the fields that matter.
    func testReadsRunningTasksFromJobState() throws {
        let data = Data(try Fixtures.string("job-state.json").utf8)
        XCTAssertEqual(BackgroundJobState.runningTaskIDs(data), ["bo84wji32"])
        XCTAssertEqual(BackgroundJobState.runningTaskIDs(Data(#"{"fan":[]}"#.utf8)), [])
        XCTAssertEqual(BackgroundJobState.runningTaskIDs(Data(#"{"fan":[{"id":"b1","doneAt":null}]}"#.utf8)), ["b1"])
        XCTAssertNil(BackgroundJobState.runningTaskIDs(Data(#"{"state":"working"}"#.utf8)), "no task list")
        XCTAssertNil(BackgroundJobState.runningTaskIDs(Data("broken".utf8)))
    }

    func testTasksAreSaved() throws {
        var session = Session(projectID: UUID(), name: "tests", workingDirectory: "/code")
        session.backgroundTasks = ["b1", "a2"]
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.backgroundTasks, ["b1", "a2"])

        let old = try JSONDecoder().decode(Session.self, from: Data(#"{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","name":"x","workingDirectory":"/code","createdAt":0}"#.utf8))
        XCTAssertEqual(old.backgroundTasks, [], "saved before tasks were")
    }

    /// Saves one session in `status` with `tasks`, writes the job state when
    /// given, and launches.
    @MainActor
    private func launch(agentID: String? = "a1", status: SessionStatus = .working, tasks: [String],
                        jobState: String? = nil) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: "/code/DigiScript")
        var session = Session(projectID: p, claudeSessionID: "a", hasConversation: true, name: "tests",
                              workingDirectory: "/code/DigiScript", status: status)
        session.agentID = agentID
        session.backgroundTasks = tasks
        try state.workspace.addSession(session)
        store.state = state
        claudeHome = try makeTemporaryDirectory()
        if let jobState, let agentID {
            let url = BackgroundJobState.url(claudeHome: claudeHome, agentID: agentID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(jobState.utf8).write(to: url)
        }
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: claudeHome),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             runner: FakeRunner(), locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        return (model, session.id)
    }

    private func agent(pid: Int?, status: String?) -> BackgroundAgent {
        BackgroundAgent(id: "a1", sessionID: "a", cwd: "/code/DigiScript", name: nil, pid: pid, status: status,
                        state: "working", waitingFor: nil, startedAt: nil)
    }

    func testStillRunningTasksKeepItWorking() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try launch(tasks: ["b1"], jobState: #"{"fan":[{"id":"b1","kind":"shell","startedAt":1}]}"#)
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
            XCTAssertEqual(model.workspace.session(id)?.backgroundTasks, ["b1"])
            model.apply([agent(pid: 5, status: "idle")])
            XCTAssertEqual(model.workspace.session(id)?.status, .working, "an idle agent with tasks running")
        }
    }

    func testTasksThatFinishedWhileClosedComplete() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try launch(tasks: ["b1"], jobState: #"{"fan":[{"id":"b1","kind":"shell","startedAt":1,"doneAt":2}]}"#)
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertEqual(model.workspace.session(id)?.backgroundTasks, [])
        }
    }

    /// The finished task woke it, and that turn started another.
    func testTasksStartedWhileClosedAreFound() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try launch(status: .completed, tasks: [], jobState: #"{"fan":[{"id":"b2","kind":"agent","startedAt":3}]}"#)
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
            XCTAssertEqual(model.workspace.session(id)?.backgroundTasks, ["b2"])
        }
    }

    func testAQuestionStillWaits() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try launch(status: .awaitingInput, tasks: ["b1"], jobState: #"{"fan":[{"id":"b1","kind":"shell","startedAt":1}]}"#)
            XCTAssertEqual(model.workspace.session(id)?.status, .awaitingInput)
            XCTAssertEqual(model.workspace.session(id)?.backgroundTasks, ["b1"])
        }
    }

    /// No job state to check (a CLI without one): the saved list stands
    /// until the agent list says otherwise.
    func testWithoutJobStateTheAgentListDecides() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try launch(tasks: ["b1"])
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
            model.apply([agent(pid: 5, status: "idle")])
            XCTAssertEqual(model.workspace.session(id)?.status, .working)
            model.apply([agent(pid: nil, status: nil)])
            XCTAssertEqual(model.workspace.session(id)?.status, .completed, "its process has gone")
            XCTAssertEqual(model.workspace.session(id)?.backgroundTasks, [])
        }
    }

    func testAnAgentNoLongerListedTakesItsTasks() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try launch(tasks: ["b1"])
            model.apply([])
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertEqual(model.workspace.session(id)?.backgroundTasks, [])
        }
    }

    /// A session running directly in a tab ended with the app.
    func testWithoutAnAgentTasksEndWithTheApp() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try launch(agentID: nil, tasks: ["b1"])
            XCTAssertEqual(model.workspace.session(id)?.status, .completed)
            XCTAssertEqual(model.workspace.session(id)?.backgroundTasks, [])
        }
    }
}
