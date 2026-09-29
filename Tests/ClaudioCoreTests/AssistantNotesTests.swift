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

            f.model.updateNoteDraft("  Maximising the Shell panel flickers once.\n")
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

    func testTheLinkCanBeRemovedForAThoughtThatIsntAboutTheSession() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.select(f.sessions[1])
            f.model.beginNoteCapture()
            f.model.updateNoteDraft("A new feature idea")
            f.model.unlinkNoteCapture()
            XCTAssertNil(f.model.noteCapture?.sessionID)
            XCTAssertEqual(f.model.noteCaptureLinkText, "Not linked to a session")

            f.model.beginNoteCapture()
            XCTAssertNil(f.model.noteCapture?.sessionID, "New Note again doesn't put the link back")
            XCTAssertEqual(f.model.noteDraft, "A new feature idea", "or lose what's typed")

            let note = try XCTUnwrap(f.model.saveNoteCapture())
            XCTAssertNil(note.sessionID)
            XCTAssertNil(note.sessionName)
            XCTAssertEqual(f.model.metaLine(for: note), "You · now")

            f.model.beginNoteCapture()
            XCTAssertEqual(f.model.noteCapture?.sessionID, f.sessions[1], "the next note is linked again")
            f.model.cancelNoteCapture()
            f.model.unlinkNoteCapture()
            XCTAssertNil(f.model.noteCapture, "nothing to unlink without a capture")
        }
    }

    func testBlankNotesAreNotSaved() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.beginNoteCapture()
            f.model.updateNoteDraft(" \n ")
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
            f.model.updateNoteDraft("Typed")
            f.model.beginNoteCapture()
            XCTAssertEqual(f.model.noteDraft, "Typed", "pressing it again keeps what's typed")
            f.model.cancelNoteCapture()
            XCTAssertNil(f.model.noteCapture)
        }
    }

    func testTheBoxOnlyCountsAsShowingWhereItIsVisible() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.select(f.sessions[0])
            f.model.beginNoteCapture()
            XCTAssertTrue(f.model.isNoteCaptureShowing)
            f.model.toggleTool(.sessions)
            XCTAssertFalse(f.model.isNoteCaptureShowing, "hidden behind another tool, terminals get the keyboard back")
            f.model.toggleTool(.assistant)
            XCTAssertTrue(f.model.isNoteCaptureShowing)
            f.model.select(f.sessions[2])
            XCTAssertFalse(f.model.isNoteCaptureShowing, "another project's Assistant doesn't show it")
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

    func testDecoding() throws {
        let id = UUID()
        let note = #"{"id":"\#(id.uuidString)","text":"Hi","author":"session","createdAt":"2026-09-28T10:00:00Z"}"#
        let data = try JSONFileStore.decoder.decode(AssistantData.self, from: Data(#"{"notes":[\#(note)]}"#.utf8))
        XCTAssertEqual(data.version, AssistantData.currentVersion, "a file without a version is version 1")
        XCTAssertEqual(data.notes.first?.author, .session)
        XCTAssertNil(data.notes.first?.sessionID, "optional fields may be missing")
        XCTAssertEqual(try JSONFileStore.decoder.decode(AssistantData.self, from: Data("{}".utf8)), AssistantData())

        let unknownAuthor = note.replacingOccurrences(of: #""session""#, with: #""someoneNew""#)
        let withUnknown = try JSONFileStore.decoder.decode(AssistantData.self, from: Data(#"{"notes":[\#(unknownAuthor)]}"#.utf8))
        XCTAssertEqual(withUnknown.notes, [], "rewriting an unknown author as a known one would change the note…")
        XCTAssertEqual(withUnknown.unreadableNotes.first?["author"], .string("someoneNew"), "…so it's kept as it was")
        XCTAssertThrowsError(try JSONFileStore.decoder.decode(AssistantData.self, from: Data(#"{"version":3,"notes":[]}"#.utf8)),
                             "a newer Claudio's file isn't read, so it can't be downgraded")

        let tools = try JSONDecoder().decode(ToolWindows.self, from: Data(#"{"left":"assistant"}"#.utf8))
        XCTAssertEqual(tools.left, .assistant)
    }

    func testANewerVersionsFileIsLeftAlone() throws {
        let root = try makeTemporaryDirectory()
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let project = state.workspace.addProject(path: "/code/app")
            let store = AssistantFileStore(root: root)
            let file = try XCTUnwrap(store.location(projectID: project).map(URL.init(fileURLWithPath:)))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let newer = #"{"version":3,"notes":[],"skills":[{"name":"Something a later step knows about"}]}"#
            try Data(newer.utf8).write(to: file)

            let memory = MemoryStore()
            memory.state = state
            let model = AppModel(store: memory, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 assistantStore: store,
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            XCTAssertTrue(model.isAssistantDataUnreadable(project))
            XCTAssertNil(model.addNote("New", author: .user, projectID: project, sessionID: nil))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), newer, "its plan survives")
            XCTAssertEqual(model.log.entries.first(where: { $0.title.hasPrefix("Couldn't read the assistant") })?.detail?.hasPrefix(file.path), true,
                           "the log says which file")
        }
    }

    func testAnUnreadableProjectOpensTheAssistantWithoutACapture() throws {
        try MainActor.assumeIsolated {
            let assistant = ThrowingAssistantStore()
            let f = try makeFixture(assistant: assistant)
            XCTAssertTrue(f.model.isAssistantDataUnreadable(f.projects[0]), "load threw")
            f.model.beginNoteCapture()
            XCTAssertEqual(f.model.toolWindows.visibleLeft, .assistant, "the Assistant says why")
            XCTAssertNil(f.model.noteCapture, "there's nowhere for a note to go")
        }
    }

    func testOneUnreadableProjectDoesntAffectAnother() throws {
        try MainActor.assumeIsolated {
            let assistant = MemoryAssistantStore()
            var f = try makeFixture(assistant: assistant)
            f.model.addNote("Kept", author: .user, projectID: f.projects[1], sessionID: nil)
            // Relaunch with the first project's file unreadable.
            let broken = SelectivelyBrokenStore(wrapping: assistant, unreadable: f.projects[0])
            let store = MemoryStore()
            store.state = f.model.state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 assistantStore: broken,
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            f = Fixture(model: model, assistant: assistant, projects: f.projects, sessions: f.sessions)
            XCTAssertTrue(model.isAssistantDataUnreadable(f.projects[0]))
            XCTAssertFalse(model.isAssistantDataUnreadable(f.projects[1]))
            model.addNote("Added", author: .user, projectID: f.projects[1], sessionID: nil)
            XCTAssertEqual(assistant.data[f.projects[1]]?.notes.map(\.text), ["Kept", "Added"])
        }
    }

    func testAFailedSaveKeepsTheDraftAndSaysSo() throws {
        try MainActor.assumeIsolated {
            let assistant = ThrowingAssistantStore(failLoad: false, failSave: true)
            let f = try makeFixture(assistant: assistant)
            f.model.beginNoteCapture()
            f.model.updateNoteDraft("X")
            XCTAssertNil(f.model.saveNoteCapture())
            XCTAssertEqual(f.model.notes(inProject: f.projects[0]), [])
            XCTAssertNil(f.model.toast, "no \"Saved to Notes\"")
            XCTAssertNotNil(f.model.noteCapture, "the box stays open")
            XCTAssertEqual(f.model.noteDraft, "X", "with what was typed")
            XCTAssertNotNil(f.model.errorMessage)
            XCTAssertEqual(assistant.audit.count, 1, "the audit comes first, so it has the attempt")
        }
    }

    func testAFailedAuditStopsTheChange() throws {
        try MainActor.assumeIsolated {
            let assistant = ThrowingAssistantStore(failLoad: false, failAudit: true)
            let f = try makeFixture(assistant: assistant)
            XCTAssertNil(f.model.addNote("X", author: .user, projectID: f.projects[0], sessionID: nil))
            XCTAssertEqual(assistant.saves, 0, "nothing lands without a record that can reverse it")
            XCTAssertEqual(f.model.notes(inProject: f.projects[0]), [])
            XCTAssertNotNil(f.model.errorMessage)
        }
    }

    func testAuditAppendsNeverReplaceTheLog() throws {
        let root = try makeTemporaryDirectory()
        let store = AssistantFileStore(root: root)
        let project = UUID()
        let url = store.directory(projectID: project).appendingPathComponent("audit.jsonl")
        let entry = AuditEntry(at: Date(timeIntervalSince1970: 0), actor: .user, action: .noteAdded, cause: "ui")

        try store.appendAudit(entry, projectID: project)
        // A write that stopped part-way, with no newline.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"trunc"#.utf8))
        try handle.close()
        try store.appendAudit(entry, projectID: project)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 4, "entry, the partial line, entry, and the final newline")
        XCTAssertEqual(lines[1], #"{"trunc"#)
        XCTAssertNoThrow(try JSONFileStore.decoder.decode(AuditEntry.self, from: Data(lines[2].utf8)), "not joined onto it")

        // A log that can't be opened is an error, not a new log. (A directory
        // in its place, since CI's Linux tests run as root, which ignores
        // read-only permissions.)
        let other = UUID()
        let blocked = store.directory(projectID: other).appendingPathComponent("audit.jsonl")
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("kept"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.appendAudit(entry, projectID: other))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("kept").path), "not replaced")
    }

    func testNewNoteAgainAsksForTheKeyboard() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.select(f.sessions[0])
            f.model.beginNoteCapture()
            f.model.updateNoteDraft("Half a thought")
            let request = f.model.noteCaptureFocusRequest
            f.model.beginNoteCapture()
            XCTAssertNotEqual(f.model.noteCaptureFocusRequest, request, "the open box takes the keyboard back")
            XCTAssertEqual(f.model.noteDraft, "Half a thought")
        }
    }

    func testMetaLineFollowsRenamesAndOutlivesTheSession() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let note = try XCTUnwrap(f.model.addNote("x", author: .user, projectID: f.projects[0], sessionID: f.sessions[1]))
            f.model.renameSession(f.sessions[1], to: "Renamed")
            XCTAssertEqual(f.model.metaLine(for: note), "You · linked to Renamed · now", "the session's current name")
            f.model.deleteSession(f.sessions[1], .claudioOnly)
            XCTAssertEqual(f.model.metaLine(for: note), "You · linked to Shell Follow Up · now",
                           "the name it had when the note was written")
        }
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

private struct StoreFailure: Error {}

/// An assistant store that fails where it's told to.
private final class ThrowingAssistantStore: AssistantStoring {
    let failLoad: Bool
    let failSave: Bool
    let failAudit: Bool
    var saves = 0
    var audit: [AuditEntry] = []

    init(failLoad: Bool = true, failSave: Bool = false, failAudit: Bool = false) {
        self.failLoad = failLoad
        self.failSave = failSave
        self.failAudit = failAudit
    }

    func load(projectID: UUID) throws -> AssistantData {
        if failLoad { throw StoreFailure() }
        return AssistantData()
    }

    func save(_ data: AssistantData, projectID: UUID) throws {
        if failSave { throw StoreFailure() }
        saves += 1
    }

    func appendAudit(_ entry: AuditEntry, projectID: UUID) throws {
        if failAudit { throw StoreFailure() }
        audit.append(entry)
    }
}

/// A memory store with one project whose file can't be read.
private final class SelectivelyBrokenStore: AssistantStoring {
    let wrapped: MemoryAssistantStore
    let unreadable: UUID

    init(wrapping wrapped: MemoryAssistantStore, unreadable: UUID) {
        self.wrapped = wrapped
        self.unreadable = unreadable
    }

    func load(projectID: UUID) throws -> AssistantData {
        if projectID == unreadable { throw StoreFailure() }
        return try wrapped.load(projectID: projectID)
    }

    func save(_ data: AssistantData, projectID: UUID) throws { try wrapped.save(data, projectID: projectID) }
    func appendAudit(_ entry: AuditEntry, projectID: UUID) throws { try wrapped.appendAudit(entry, projectID: projectID) }
}
