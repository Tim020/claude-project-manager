import XCTest
@testable import ClaudioCore

/// Suggestions on notes survive a relaunch, and Check Again asks afresh.
final class AssistantSuggestionTests: XCTestCase {
    /// Answers assistant calls with `reply`; everything else as `FakeRunner`.
    private final class Runner: CommandRunning, @unchecked Sendable {
        let base = FakeRunner()
        private let lock = NSLock()
        private var _reply = CommandResult(exitCode: 0, output: "", errorOutput: "")
        private var _calls = 0
        var reply: CommandResult {
            get { lock.withLock { _reply } }
            set { lock.withLock { _reply = newValue } }
        }
        var calls: Int { lock.withLock { _calls } }

        func run(_ command: TerminalLaunch) async -> CommandResult {
            guard command.claudeArguments.contains("--json-schema") else { return await base.run(command) }
            return lock.withLock { _calls += 1; return _reply }
        }
    }

    private let store = MemoryStore()
    private let assistant = MemoryAssistantStore()
    private let runner = Runner()
    private var project = UUID()

    override func setUp() {
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        project = store.state.workspace.addProject(path: "/code/app")
    }

    /// A launch of Claudio on the same state and assistant files.
    @MainActor private func launch() throws -> AppModel {
        AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                 assistantStore: assistant, locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
    }

    private func answer(_ json: String) -> CommandResult {
        CommandResult(exitCode: 0, output: #"{"is_error":false,"structured_output":\#(json)}"#, errorOutput: "")
    }

    private let createReply = #"{"kind":"bug","promote":true,"title":"Fix the flicker","duplicateOf":null,"reason":"Reads like a bug."}"#

    func testSuggestionsShowAgainAfterARelaunch() async throws {
        runner.reply = answer(createReply)
        let first = try await MainActor.run { try launch() }
        let noteID = try await MainActor.run { () -> UUID in
            let note = try XCTUnwrap(first.addNote("The panel flickers", author: .user, projectID: project, sessionID: nil))
            first.requestPromote(note.id, projectID: project)
            XCTAssertEqual(assistant.suggestions[project] ?? [:], [:], "Checking… isn't saved: its call ends with the app")
            return note.id
        }
        await first.waitForAssistantJobs()
        let expected = NoteSuggestion.promote(title: "Fix the flicker", status: .planned, reason: "Reads like a bug.")
        XCTAssertEqual(assistant.suggestions[project]?[noteID], expected, "saved as it's shown")

        let second = try await MainActor.run { try launch() }
        await MainActor.run {
            XCTAssertEqual(second.noteSuggestions[noteID], expected, "the relaunch looks as it did")
            second.keepAsNote(noteID)
        }
        XCTAssertEqual(assistant.suggestions[project] ?? [:], [:], "answering it removes it from the file")
    }

    func testSuggestionsThatNoLongerApplyArentRestored() async throws {
        let (noteIDs, itemID) = try await MainActor.run { () -> ([UUID], UUID) in
            let model = try launch()
            let target = try XCTUnwrap(model.addNote("Target", author: .user, projectID: project, sessionID: nil))
            let item = try XCTUnwrap(model.promoteNote(target.id, projectID: project))
            let a = try XCTUnwrap(model.addNote("A", author: .user, projectID: project, sessionID: nil))
            let b = try XCTUnwrap(model.addNote("B", author: .user, projectID: project, sessionID: nil))
            let c = try XCTUnwrap(model.addNote("C", author: .user, projectID: project, sessionID: nil))
            // As a previous launch left them.
            assistant.suggestions[project] = [
                a.id: .attach(itemID: item.id, reason: "Same work."),
                b.id: .promote(title: "B", status: .planned, reason: "Work."),
                c.id: .promote(title: "C", status: .planned, reason: "Work."),
                UUID(): .promote(title: "Gone", status: .planned, reason: "A note since deleted."),
            ]
            // Since then: the target item is done, and C joined an item.
            model.setStatus(.done, ofItem: item.id, projectID: project)
            model.attachNote(c.id, to: item.id, projectID: project)
            return ([a.id, b.id, c.id], item.id)
        }
        let model = try await MainActor.run { try launch() }
        await MainActor.run {
            XCTAssertNil(model.noteSuggestions[noteIDs[0]], "an Attach to a done item")
            XCTAssertEqual(model.noteSuggestions[noteIDs[1]], .promote(title: "B", status: .planned, reason: "Work."))
            XCTAssertNil(model.noteSuggestions[noteIDs[2]], "a note that has an item now")
            XCTAssertEqual(model.noteSuggestions.count, 1)
            XCTAssertNotNil(model.item(itemID, inProject: project))
        }
        XCTAssertEqual(assistant.suggestions[project]?.keys.sorted(), [noteIDs[1]], "and the file keeps only what's showing")
    }

    func testCheckAgainAsksAfreshAndKeepsTheOldAnswerIfItFails() async throws {
        runner.reply = answer(createReply)
        let model = try await MainActor.run { try launch() }
        let noteID = try await MainActor.run { () -> UUID in
            let note = try XCTUnwrap(model.addNote("The panel flickers", author: .user, projectID: project, sessionID: nil))
            model.requestPromote(note.id, projectID: project)
            return note.id
        }
        await model.waitForAssistantJobs()
        let first = await MainActor.run { model.noteSuggestions[noteID] }

        runner.reply = answer(#"{"kind":"idea","promote":true,"title":"Smoother resizing","duplicateOf":null,"reason":"An idea."}"#)
        await MainActor.run { model.recheckNote(noteID, projectID: project) }
        await model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertEqual(model.noteSuggestions[noteID], .promote(title: "Smoother resizing", status: .idea, reason: "An idea."),
                           "the new answer replaces the old")
        }

        runner.reply = CommandResult(exitCode: 1, output: #"{"is_error":true,"result":"Overloaded"}"#, errorOutput: "")
        await MainActor.run { model.recheckNote(noteID, projectID: project) }
        await model.waitForAssistantJobs()
        await MainActor.run {
            XCTAssertEqual(model.noteSuggestions[noteID], .promote(title: "Smoother resizing", status: .idea, reason: "An idea."),
                           "a failed check leaves the earlier answer")
            XCTAssertNotNil(model.errorMessage, "and says why")
        }
        XCTAssertEqual(runner.calls, 3)
        XCTAssertNotEqual(first, nil)
    }

    func testTheSuggestionsFile() throws {
        let root = try makeTemporaryDirectory()
        let files = AssistantFileStore(root: root)
        let project = UUID()
        let note = UUID(), other = UUID()
        let saved: [UUID: NoteSuggestion] = [
            note: .promote(title: "Fix it", status: .idea, reason: "An idea."),
            other: .attach(itemID: UUID(), reason: "Same work."),
        ]
        try files.saveSuggestions(saved, projectID: project)
        XCTAssertEqual(files.loadSuggestions(projectID: project), saved)

        let url = files.directory(projectID: project).appendingPathComponent("suggestions.json")
        try Data(#"{"\#(note.uuidString.lowercased())":{"somethingNew":{}},"not-a-uuid":{}}"#.utf8).write(to: url)
        XCTAssertEqual(files.loadSuggestions(projectID: project), [:], "entries that can't be read are skipped")
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(files.loadSuggestions(projectID: project), [:], "a file that can't be read is just empty")

        try files.saveSuggestions([:], projectID: project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing showing, no file")
    }
}
