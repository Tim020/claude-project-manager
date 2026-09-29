import XCTest
@testable import ClaudioCore

final class AssistantPlanTests: XCTestCase {
    private struct Fixture {
        let model: AppModel
        let assistant: MemoryAssistantStore
        let project: UUID
        let folder: UUID
        /// "Shell Terminal" in the folder "In-built Shell"; "Loose" unfiled.
        let sessions: [UUID]
    }

    @MainActor private func makeFixture(assistant: MemoryAssistantStore = MemoryAssistantStore()) throws -> Fixture {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let sessions = [
            Session(projectID: project, name: "Shell Terminal", workingDirectory: "/code/app", status: .awaitingInput),
            Session(projectID: project, name: "Loose", workingDirectory: "/code/app", status: .awaitingInput),
        ]
        for session in sessions { try state.workspace.addSession(session) }
        let folder = try state.workspace.createFolder(in: project, named: "In-built Shell", containing: sessions[0].id)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             assistantStore: assistant,
                             locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
        return Fixture(model: model, assistant: assistant, project: project, folder: folder, sessions: sessions.map(\.id))
    }

    func testPromoteMakesAPlannedItemWithTheNoteAttached() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let note = try XCTUnwrap(f.model.addNote("Shell panel height resets on relaunch. It should be remembered per project.",
                                                      author: .user, projectID: f.project, sessionID: f.sessions[0]))
            let item = try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project))
            XCTAssertEqual(item.title, "Shell panel height resets on relaunch", "the note's first sentence")
            XCTAssertEqual(item.status, .planned)
            XCTAssertEqual(item.folderID, f.folder, "the folder of the note's session")
            XCTAssertEqual(f.model.folderName(of: item, inProject: f.project), "In-built Shell")
            XCTAssertEqual(f.model.notes(forItem: item.id, inProject: f.project).map(\.id), [note.id])
            XCTAssertEqual(f.model.toast?.text, "Added to Plan as Planned")
            XCTAssertNil(f.model.promoteNote(note.id, projectID: f.project), "a note joins one item at most")

            let audit = try XCTUnwrap(f.assistant.audit[f.project]).suffix(2)
            XCTAssertEqual(audit.map(\.action), [.itemAdded, .noteChanged])
            XCTAssertEqual(audit.first?.afterItem, item)
            XCTAssertEqual(audit.last?.after?.itemID, item.id)
            XCTAssertEqual(f.assistant.data[f.project]?.items, [item], "saved")
        }
    }

    func testPromoteAsAnIdeaAndWithASuggestedTitle() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let note = try XCTUnwrap(f.model.addNote("Could the README list every shortcut?", author: .user,
                                                      projectID: f.project, sessionID: f.sessions[1]))
            let item = try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project, title: "  Keyboard shortcuts in the README\nextra",
                                                         status: .idea))
            XCTAssertEqual(item.title, "Keyboard shortcuts in the README", "one clean line")
            XCTAssertEqual(item.status, .idea)
            XCTAssertNil(item.folderID, "an unfiled session's note goes to Unfiled")
            XCTAssertEqual(f.model.folderName(of: item, inProject: f.project), "Unfiled")
            XCTAssertEqual(f.model.toast?.text, "Added to Plan as an Idea")

            let blank = try XCTUnwrap(f.model.addNote("Blank title", author: .user, projectID: f.project, sessionID: nil))
            XCTAssertEqual(f.model.promoteNote(blank.id, projectID: f.project, title: "   ")?.title, "Blank title",
                           "an empty suggestion falls back to the note")
        }
    }

    func testTitles() {
        XCTAssertEqual(PlanTitle.from("Fix it."), "Fix it")
        XCTAssertEqual(PlanTitle.from("First line\nSecond line"), "First line")
        XCTAssertEqual(PlanTitle.from("Version 2.1 is out. Upgrade"), "Version 2.1 is out", "a dot inside a word isn't a sentence end")
        let long = String(repeating: "word ", count: 30)
        let title = PlanTitle.clean(long)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, PlanTitle.maxLength + 1)
        XCTAssertFalse(title.contains("  "))
    }

    func testAttachDetachAndMetaLines() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let first = try XCTUnwrap(f.model.addNote("One", author: .user, projectID: f.project, sessionID: nil))
            let second = try XCTUnwrap(f.model.addNote("Two", author: .session, projectID: f.project, sessionID: f.sessions[0]))
            let item = try XCTUnwrap(f.model.promoteNote(first.id, projectID: f.project))
            XCTAssertEqual(f.model.metaLine(for: item, inProject: f.project), "1 note")

            XCTAssertTrue(f.model.attachNote(second.id, to: item.id, projectID: f.project))
            XCTAssertEqual(f.model.toast?.text, "Attached to \"One\"")
            XCTAssertFalse(f.model.attachNote(second.id, to: item.id, projectID: f.project), "already there")
            XCTAssertFalse(f.model.attachNote(second.id, to: UUID(), projectID: f.project), "no such item")
            var shown = try XCTUnwrap(f.model.item(item.id, inProject: f.project))
            shown.issue = "#17"
            shown.sessionID = f.sessions[0]
            XCTAssertEqual(f.model.metaLine(for: shown, inProject: f.project), "#17 · 2 notes · Shell Terminal")
            XCTAssertEqual(f.model.notes(forItem: item.id, inProject: f.project).map(\.text), ["Two", "One"], "newest first")

            f.model.detachNote(second.id, projectID: f.project)
            XCTAssertEqual(f.model.notes(forItem: item.id, inProject: f.project).map(\.text), ["One"])
            XCTAssertEqual(f.model.notes(inProject: f.project).count, 2, "detaching keeps the note")
        }
    }

    func testStatusRenameAndGroups() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let ids = try ["A", "B", "C"].map { text -> UUID in
                let note = try XCTUnwrap(f.model.addNote(text, author: .user, projectID: f.project, sessionID: nil))
                return try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project)).id
            }
            f.model.setStatus(.idea, ofItem: ids[0], projectID: f.project)
            f.model.setStatus(.done, ofItem: ids[1], projectID: f.project)
            f.model.renameItem(ids[2], to: "  C, renamed  ", projectID: f.project)
            f.model.renameItem(ids[2], to: "   ", projectID: f.project)

            let groups = f.model.planGroups(inProject: f.project)
            XCTAssertEqual(groups.map(\.status), [.planned, .idea, .done], "in the design's order, empty groups left out")
            XCTAssertEqual(groups.map { $0.items.map(\.title) }, [["C, renamed"], ["A"], ["B"]], "a blank name is ignored")
            let entries = try XCTUnwrap(f.assistant.audit[f.project])
            XCTAssertEqual(entries.filter { $0.action == .itemChanged }.count, 3, "a no-op rename isn't recorded")

            f.model.setStatus(.done, ofItem: ids[1], projectID: f.project)
            XCTAssertEqual(try XCTUnwrap(f.assistant.audit[f.project]).count, entries.count, "nor is an unchanged status")
        }
    }

    func testDeletingAnItemKeepsItsNotes() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let note = try XCTUnwrap(f.model.addNote("Keep me", author: .user, projectID: f.project, sessionID: nil))
            let item = try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project))
            f.model.openPlanItem(item.id, projectID: f.project)
            XCTAssertEqual(f.model.shownPlanItem, f.model.item(item.id, inProject: f.project))

            f.model.deleteItem(item.id, projectID: f.project)
            XCTAssertEqual(f.model.items(inProject: f.project), [])
            XCTAssertEqual(f.model.notes(inProject: f.project).map(\.itemID), [nil], "detached, not deleted")
            XCTAssertEqual(f.model.assistantPanel, .list, "the item's view closes")
            XCTAssertEqual(f.assistant.audit[f.project]?.suffix(2).map(\.action), [.itemDeleted, .noteChanged])
        }
    }

    func testThePanelShowsOnlyTheAssistantsProjectsItem() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let note = try XCTUnwrap(f.model.addNote("x", author: .user, projectID: f.project, sessionID: nil))
            let item = try XCTUnwrap(f.model.promoteNote(note.id, projectID: f.project))
            f.model.setAssistantListMode(.notes)
            f.model.openPlanItem(item.id, projectID: f.project)
            XCTAssertEqual(f.model.assistantListMode, .plan, "back goes to the plan")
            f.model.openPlanItem(UUID(), projectID: f.project)
            XCTAssertNil(f.model.shownPlanItem, "a missing item shows the list")
            f.model.openPlanItem(item.id, projectID: UUID())
            XCTAssertNil(f.model.shownPlanItem, "so does another project's")
            f.model.closePlanItem()
            XCTAssertEqual(f.model.assistantPanel, .list)

            f.model.openPlanItem(item.id, projectID: f.project)
            f.model.beginNoteCapture()
            XCTAssertEqual(f.model.assistantPanel, .list, "New Note shows the list")
            XCTAssertEqual(f.model.assistantListMode, .notes, "on Notes, where the note will appear")
        }
    }

    func testModeIsSavedPerProject() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            XCTAssertEqual(f.model.assistantMode(ofProject: f.project), .automatic, "the default")
            f.model.setAssistantMode(.off, projectID: f.project)
            XCTAssertEqual(f.assistant.data[f.project]?.mode, .off)
            XCTAssertNil(f.assistant.audit[f.project], "a setting, not a change to notes or items")
        }
    }

    // MARK: - The file

    func testVersion1FilesReadAndAreWrittenAsVersion2() throws {
        let json = #"{"version":1,"notes":[{"id":"\#(UUID().uuidString)","text":"Old","author":"user","createdAt":"2026-09-28T10:00:00Z"}]}"#
        let data = try JSONFileStore.decoder.decode(AssistantData.self, from: Data(json.utf8))
        XCTAssertEqual(data.notes.map(\.text), ["Old"])
        XCTAssertEqual(data.items, [])
        XCTAssertEqual(data.mode, .automatic)
        let written = try JSONDecoder().decode(JSONValue.self, from: JSONFileStore.encoder.encode(data))
        XCTAssertEqual(written["version"], .number(2), "so step 1's Claudio refuses it rather than dropping the plan")
    }

    func testUnreadableEntriesAreKeptAsTheyWere() throws {
        let good = UUID()
        let json = """
        {"version":2,"mode":"manual","notes":[
          {"id":"\(good.uuidString)","text":"Fine","author":"user","createdAt":"2026-09-28T10:00:00Z"},
          {"id":"not-a-uuid","text":"Hand-edited","author":"user","createdAt":"2026-09-28T10:00:00Z"}
        ],"items":[
          {"id":"\(UUID().uuidString)","title":"Odd","status":"someNewStatus","createdAt":"2026-09-28T10:00:00Z"}
        ]}
        """
        let data = try JSONFileStore.decoder.decode(AssistantData.self, from: Data(json.utf8))
        XCTAssertEqual(data.notes.map(\.id), [good], "the readable note shows")
        XCTAssertEqual(data.unreadableCount, 2)
        XCTAssertEqual(data.mode, .manual)

        // Written back unchanged, whatever else changes.
        var changed = data
        changed.notes.append(ProjectNote(text: "New", author: .user, createdAt: Date(timeIntervalSince1970: 0)))
        let reread = try JSONFileStore.decoder.decode(AssistantData.self, from: JSONFileStore.encoder.encode(changed))
        XCTAssertEqual(reread.unreadableNotes, data.unreadableNotes)
        XCTAssertEqual(reread.unreadableItems, data.unreadableItems)
        XCTAssertEqual(reread.unreadableNotes.first?["text"], .string("Hand-edited"))
        XCTAssertEqual(reread.notes.map(\.text), ["Fine", "New"])
    }

    func testTheCountOfUnreadableEntriesReachesThePanel() throws {
        try MainActor.assumeIsolated {
            let assistant = MemoryAssistantStore()
            var broken = AssistantData()
            broken.unreadableNotes = [.object(["text": .string("?")])]
            let f = try makeFixture(assistant: assistant)
            assistant.data[f.project] = broken
            let store = MemoryStore()
            store.state = f.model.state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 assistantStore: assistant,
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            XCTAssertEqual(model.unreadableEntryCount(inProject: f.project), 1)
            XCTAssertFalse(model.isAssistantDataUnreadable(f.project), "the rest of the project still works")
            model.addNote("Still saves", author: .user, projectID: f.project, sessionID: nil)
            XCTAssertEqual(assistant.data[f.project]?.unreadableNotes.count, 1, "and keeps the bad entry")
        }
    }
}
