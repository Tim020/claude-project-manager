import XCTest
@testable import ClaudioCore

/// Session names stay in step with Claude Code's own title (`/rename`), which
/// it stores as a `custom-title` record in the session's history file.
final class TitleSyncTests: XCTestCase {
    let repo = "/Users/tim/Documents/Code/DigiScript"
    let sid = "b3f8f7e8-3932-40da-8035-6f1c5e5cecfd"
    let prompt = #"{"type":"user","cwd":"/Users/tim/Documents/Code/DigiScript","message":{"content":"review 1427"},"timestamp":"2026-09-25T10:00:00Z"}"#

    private func historyFile(home: URL) -> URL {
        home.appendingPathComponent("projects")
            .appendingPathComponent(SessionDiscovery.directoryName(forProjectPath: repo))
            .appendingPathComponent("\(sid).jsonl")
    }

    private func writeHistory(home: URL, _ lines: [String]) throws {
        let file = historyFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func title(_ text: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(text)","sessionId":"\#(sid)"}"#
    }

    func testDiscoveryReportsTheLatestCustomTitle() {
        let found = SessionDiscovery.summarize(lines: [prompt, title("first"), title("second")], claudeSessionID: sid,
                                               fallbackDate: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(found?.customTitle, "second")
        XCTAssertNil(SessionDiscovery.summarize(lines: [prompt], claudeSessionID: sid, fallbackDate: Date())?.customTitle)
    }

    func testTitleRecordIsWhatSlashRenameWrites() throws {
        let line = SessionTitleWriter.record(title: #"pr "review" 1427"#, claudeSessionID: sid)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(value["type"]?.stringValue, "custom-title")
        XCTAssertEqual(value["customTitle"]?.stringValue, #"pr "review" 1427"#)
        XCTAssertEqual(value["sessionId"]?.stringValue, sid)
        XCTAssertFalse(line.contains("\n"))
    }

    func testAppendAddsALineAndNeverCreatesAFile() throws {
        let home = try makeTemporaryDirectory()
        let file = historyFile(home: home)
        XCTAssertFalse(SessionTitleWriter.append(title: "x", claudeSessionID: sid, to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prompt.write(to: file, atomically: true, encoding: .utf8)   // no trailing newline
        XCTAssertTrue(SessionTitleWriter.append(title: "renamed", claudeSessionID: sid, to: file))
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], prompt)
        XCTAssertEqual(SessionDiscovery.summarize(lines: lines, claudeSessionID: sid, fallbackDate: Date())?.customTitle, "renamed")
    }

    @MainActor private func makeModel(home: URL, name: String = "pr review inline 1427", custom: Bool = true) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo)
        var session = Session(projectID: p, claudeSessionID: sid, hasConversation: true, name: name, workingDirectory: repo)
        session.hasCustomName = custom
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: home),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, shell: "/bin/sh", home: "/Users/tim")
        return (model, session.id)
    }

    func testRenamingInClaudioWritesClaudeCodesTitle() async throws {
        let home = try makeTemporaryDirectory()
        try writeHistory(home: home, [prompt])
        let (model, id) = try await MainActor.run { try makeModel(home: home) }
        await MainActor.run { model.renameSession(id, to: "websocket review") }
        let text = try String(contentsOf: historyFile(home: home), encoding: .utf8)
        XCTAssertTrue(text.hasSuffix(title("websocket review") + "\n"))

        // Reading it back doesn't bounce the name around.
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.name, "websocket review") }
    }

    func testRenamingInTheTerminalRenamesTheSession() async throws {
        let home = try makeTemporaryDirectory()
        try writeHistory(home: home, [prompt, title("pr review inline 1427")])
        let (model, id) = try await MainActor.run { try makeModel(home: home) }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.name, "pr review inline 1427") }

        try writeHistory(home: home, [prompt, title("pr review inline 1427"), title("round 3 review")])
        await model.refreshAll()
        await MainActor.run {
            XCTAssertEqual(model.workspace.session(id)?.name, "round 3 review")
            XCTAssertEqual(model.workspace.session(id)?.hasCustomName, true)
        }
    }

    func testAnOlderDifferentTitleDoesntOverrideAClaudioNameAtFirstSight() async throws {
        // Renamed in Claudio before titles were synced: keep Claudio's name.
        let home = try makeTemporaryDirectory()
        try writeHistory(home: home, [prompt, title("old terminal name")])
        let (model, id) = try await MainActor.run { try makeModel(home: home, name: "my name") }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.name, "my name") }
    }

    func testSessionsWithoutACustomNameTakeClaudesTitle() async throws {
        let home = try makeTemporaryDirectory()
        try writeHistory(home: home, [prompt, title("named in terminal")])
        let (model, id) = try await MainActor.run { try makeModel(home: home, name: "review 1427", custom: false) }
        await model.refreshAll()
        await MainActor.run { XCTAssertEqual(model.workspace.session(id)?.name, "named in terminal") }
    }

    func testClaudeSessionIDIsKeptThroughDecoding() throws {
        var session = Session(projectID: UUID(), name: "s", workingDirectory: repo)
        session.claudeTitle = "t"
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.claudeTitle, "t")
    }
}
