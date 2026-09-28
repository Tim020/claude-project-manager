import XCTest
@testable import ClaudioCore

final class AssistantNotesTests: XCTestCase {
    private struct Fixture {
        let model: AppModel
        let assistant: MemoryAssistantStore
        let projects: [UUID]
        let sessions: [UUID]
    }

    /// Two projects; sessions "Shell Terminal" and "Shell Follow Up" in the first, "Other" in the second.
    @MainActor private func makeFixture(assistant: AssistantStoring? = nil, clock: @escaping () -> Date = Date.init) throws -> Fixture {
        var state = PersistedState()
        let first = state.workspace.addProject(path: "/code/app")
        let second = state.workspace.addProject(path: "/code/other")
        let sessions = [
            Session(projectID: first, name: "Shell Terminal", workingDirectory: "/code/app", status: .awaitingInput),
            Session(projectID: first, name: "Shell Follow Up", workingDirectory: "/code/app", status: .awaitingInput),
            Session(projectID: second, name: "Other", workingDirectory: "/code/other", status: .awaitingInput),
        ]
        for session in sessions { try state.workspace.addSession(session) }
        let store = MemoryStore()
        store.state = state
        let memory = MemoryAssistantStore()
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             assistantStore: assistant ?? memory,
                             locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", now: clock, home: "/")
        return Fixture(model: model, assistant: memory, projects: [first, second], sessions: sessions.map(\.id))
    }

    func testCaptureOpensTheAssistantLinkedToTheFocusedSession() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.select(f.sessions[1])
            f.model.beginNoteCapture()
            XCTAssertEqual(f.model.toolWindows.visibleLeft, .assistant, "⌘⇧N shows the Assistant")
            XCTAssertEqual(f.model.noteCapture, NoteCapture(projectID: f.projects[0], sessionID: f.sessions[1]))
            XCTAssertEqual(f.model.noteCaptureLinkText, "Linked to Shell Follow Up")

            f.model.updateNoteCapture("  Maximising the Shell panel flickers once.\n")
            let note = try XCTUnwrap(f.model.saveNoteCapture())
            XCTAssertEqual(note.text, "Maximising the Shell panel flickers once.", "trimmed")
            XCTAssertEqual(note.author, .user)
            XCTAssertEqual(note.sessionID, f.sessions[1])
            XCTAssertEqual(note.sessionName, "Shell Follow Up")
            XCTAssertNil(f.model.noteCapture, "the box closes")
            XCTAssertEqual(f.model.toast?.text, "Saved to Notes")
            XCTAssertEqual(f.assistant.data[f.projects[0]]?.notes, [note], "saved straight away")
            XCTAssertEqual(f.assistant.audit[f.projects[0]]?.map(\.action), [.noteAdded])
        }
    }

    func testBlankNotesAreNotSaved() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.beginNoteCapture()
            f.model.updateNoteCapture(" \n ")
            XCTAssertNil(f.model.saveNoteCapture())
            XCTAssertNotNil(f.model.noteCapture, "the box stays open")
            XCTAssertNil(f.model.toast)
            XCTAssertNil(f.assistant.data[f.projects[0]])
        }
    }

    func testCaptureFollowsTheSelectedSessionsProject() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            XCTAssertNil(f.model.selectedSession)
            XCTAssertEqual(f.model.assistantProjectID, f.projects[0], "the first project with nothing selected")
            f.model.beginNoteCapture()
            XCTAssertNil(f.model.noteCapture?.sessionID)
            XCTAssertEqual(f.model.noteCaptureLinkText, "Not linked to a session")

            f.model.select(f.sessions[2])
            XCTAssertEqual(f.model.assistantProjectID, f.projects[1])
            f.model.beginNoteCapture()
            XCTAssertEqual(f.model.noteCapture, NoteCapture(projectID: f.projects[1], sessionID: f.sessions[2]),
                           "a new capture for the other project")
            f.model.updateNoteCapture("Typed")
            f.model.beginNoteCapture()
            XCTAssertEqual(f.model.noteCapture?.text, "Typed", "pressing it again keeps what's typed")
            f.model.cancelNoteCapture()
            XCTAssertNil(f.model.noteCapture)
        }
    }

    func testCaptureDoesNothingWithoutProjects() throws {
        try MainActor.assumeIsolated {
            let store = MemoryStore()
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            model.beginNoteCapture()
            XCTAssertNil(model.noteCapture)
            XCTAssertEqual(model.toolWindows.visibleLeft, .sessions)
        }
    }

    func testNotesAreNewestFirstWithAMetaLinePerAuthor() throws {
        try MainActor.assumeIsolated {
            var clock = Date(timeIntervalSince1970: 1_000_000)
            let f = try makeFixture(clock: { clock })
            let project = f.projects[0]
            f.model.addNote("Mine", author: .user, projectID: project, sessionID: f.sessions[1])
            clock += 60
            f.model.addNote("Assistant's", author: .assistant, projectID: project, sessionID: f.sessions[0])
            clock += 60
            f.model.addNote("A session's", author: .session, projectID: project, sessionID: f.sessions[1])
            f.model.addNote("Unlinked", author: .user, projectID: project, sessionID: nil)
            clock += 3 * 3600

            let notes = f.model.notes(inProject: project)
            XCTAssertEqual(notes.map(\.text), ["Unlinked", "A session's", "Assistant's", "Mine"])
            XCTAssertEqual(notes.map(f.model.metaLine), [
                "You · 3h",
                "Shell Follow Up · 3h",
                "Assistant · from Shell Terminal · 3h",
                "You · linked to Shell Follow Up · 3h",
            ])
            XCTAssertEqual(notes.map(\.canUndo), [false, true, true, false], "only notes you didn't write have Undo")
            XCTAssertEqual(f.model.notes(inProject: f.projects[1]), [], "notes are per project")
        }
    }

    func testMetaLineUsesTheSessionsCurrentNameOrTheOneSaved() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var note = ProjectNote(text: "x", author: .session, sessionID: UUID(), sessionName: "Old name", createdAt: now)
        XCTAssertEqual(NoteMeta.line(for: note, sessionName: note.sessionName, now: now), "Old name · now")
        XCTAssertEqual(NoteMeta.line(for: note, sessionName: nil, now: now), "A session · now")
        note.author = .assistant
        XCTAssertEqual(NoteMeta.line(for: note, sessionName: nil, now: now), "Assistant · now")
    }

    func testUndoAndDelete() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let project = f.projects[0]
            let mine = try XCTUnwrap(f.model.addNote("Mine", author: .user, projectID: project, sessionID: nil))
            let theirs = try XCTUnwrap(f.model.addNote("Theirs", author: .session, projectID: project, sessionID: f.sessions[0],
                                                       cause: f.sessions[0].uuidString))

            f.model.undoNote(mine.id, projectID: project)
            XCTAssertEqual(f.model.notes(inProject: project).count, 2, "your own notes have no Undo")
            f.model.undoNote(theirs.id, projectID: project)
            XCTAssertEqual(f.model.notes(inProject: project).map(\.id), [mine.id])
            f.model.deleteNote(mine.id, projectID: project)
            XCTAssertEqual(f.model.notes(inProject: project), [])
            XCTAssertEqual(f.assistant.data[project]?.notes, [])

            let audit = try XCTUnwrap(f.assistant.audit[project])
            XCTAssertEqual(audit.map(\.action), [.noteAdded, .noteAdded, .noteUndone, .noteDeleted])
            XCTAssertEqual(audit.map(\.actor), [.user, .session, .user, .user])
            XCTAssertEqual(audit[1].cause, f.sessions[0].uuidString)
            XCTAssertEqual(audit[2].before, theirs, "each entry holds what it changed")
            XCTAssertEqual(audit[3].before, mine)
        }
    }

    func testNotesPersistInFiles() throws {
        let root = try makeTemporaryDirectory()
        let projectID = try MainActor.assumeIsolated { () throws -> UUID in
            let f = try makeFixture(assistant: AssistantFileStore(root: root))
            f.model.addNote("Kept", author: .user, projectID: f.projects[0], sessionID: f.sessions[0])
            f.model.addNote("Second", author: .assistant, projectID: f.projects[0], sessionID: nil)
            return f.projects[0]
        }
        let store = AssistantFileStore(root: root)
        XCTAssertEqual(try store.load(projectID: projectID).notes.map(\.text), ["Kept", "Second"])
        let auditURL = store.directory(projectID: projectID).appendingPathComponent("audit.jsonl")
        let lines = try String(contentsOf: auditURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "one line per change")
        let entry = try JSONFileStore.decoder.decode(AuditEntry.self, from: Data(lines[1].utf8))
        XCTAssertEqual(entry.action, .noteAdded)
        XCTAssertEqual(entry.after?.text, "Second")
        XCTAssertEqual(try store.load(projectID: UUID()), AssistantData(), "a project with no file has no notes")
    }

    func testNotesLoadAtLaunch() throws {
        try MainActor.assumeIsolated {
            let assistant = MemoryAssistantStore()
            let first = try makeFixture(assistant: assistant)
            first.model.addNote("From last time", author: .user, projectID: first.projects[0], sessionID: nil)
            // The same projects, as a fresh launch sees them.
            let store = MemoryStore()
            store.state = first.model.state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 assistantStore: assistant,
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            XCTAssertEqual(model.notes(inProject: first.projects[0]).map(\.text), ["From last time"])
        }
    }

    func testAnUnreadableFileIsNeverOverwritten() throws {
        let root = try makeTemporaryDirectory()
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let project = state.workspace.addProject(path: "/code/app")
            let store = AssistantFileStore(root: root)
            let file = store.directory(projectID: project).appendingPathComponent("assistant.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: file)

            let memory = MemoryStore()
            memory.state = state
            let model = AppModel(store: memory, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 assistantStore: store,
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            XCTAssertNil(model.addNote("New", author: .user, projectID: project, sessionID: nil))
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json", "left as it was")
        }
    }

    func testDecodingIsTolerant() throws {
        let id = UUID()
        let json = #"{"notes":[{"id":"\#(id.uuidString)","text":"Hi","author":"someoneNew","createdAt":"2026-09-28T10:00:00Z"}]}"#
        let data = try JSONFileStore.decoder.decode(AssistantData.self, from: Data(json.utf8))
        XCTAssertEqual(data.version, AssistantData.currentVersion)
        XCTAssertEqual(data.notes.first?.author, .assistant, "an unknown author keeps Undo")
        XCTAssertNil(data.notes.first?.sessionID)
        XCTAssertEqual(try JSONFileStore.decoder.decode(AssistantData.self, from: Data("{}".utf8)), AssistantData())

        let tools = try JSONDecoder().decode(ToolWindows.self, from: Data(#"{"left":"assistant"}"#.utf8))
        XCTAssertEqual(tools.left, .assistant)
    }

    func testToastClearsOnlyItself() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.showToast("First")
            let first = try XCTUnwrap(f.model.toast)
            f.model.showToast("Second")
            f.model.clearToast(first.id)
            XCTAssertEqual(f.model.toast?.text, "Second", "an older toast's timer doesn't clear a newer one")
        }
    }
}
