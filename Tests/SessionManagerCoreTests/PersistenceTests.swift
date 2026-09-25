import XCTest
@testable import SessionManagerCore

final class PersistenceTests: XCTestCase {
    func testMissingFileLoadsEmptyState() throws {
        let dir = try makeTemporaryDirectory()
        let store = JSONFileStore(url: dir.appendingPathComponent("state.json"))
        XCTAssertEqual(try store.load(), PersistedState())
    }

    func testSaveThenLoadRoundTripsAndCreatesDirectories() throws {
        let dir = try makeTemporaryDirectory().appendingPathComponent("nested/deeper")
        let store = JSONFileStore(url: dir.appendingPathComponent("state.json"))

        var state = PersistedState()
        let p = state.workspace.addProject(path: "/code/app")
        let f = try state.workspace.createFolder(in: p, named: "Folder")
        try state.workspace.addSession(Session(projectID: p, name: "s", workingDirectory: "/code/app",
                                               createdAt: Date(timeIntervalSince1970: 1_790_000_000.25)), toFolder: f)
        state.settings.claudePath = "/opt/claude"
        state.settings.defaultModel = "claude-opus-5-5"
        state.settings.layout = .split

        try store.save(state)
        XCTAssertEqual(try store.load(), state)
    }

    func testCorruptFileThrows() throws {
        let dir = try makeTemporaryDirectory()
        let url = dir.appendingPathComponent("state.json")
        try Data("{nope".utf8).write(to: url)
        XCTAssertThrowsError(try JSONFileStore(url: url).load())
    }

    func testSettingsDecodeWithMissingKeysUsesDefaults() throws {
        let json = #"{"workspace":{"projects":[],"sessions":[]},"settings":{}}"#
        let state = try JSONFileStore.decoder.decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.settings, AppSettings())
        XCTAssertEqual(state.settings.defaultPermissionMode, .acceptEdits)
        XCTAssertEqual(state.settings.layout, .tabs)
    }

    func testSessionDecodesOlderFilesWithoutOptionalFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FE","name":"x","workingDirectory":"/","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z"}"#
        let session = try JSONFileStore.decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.role, .code)
        XCTAssertEqual(session.permissionMode, .acceptEdits)
        XCTAssertFalse(session.isArchived)
        XCTAssertEqual(session.pullRequestURLs, [])
    }
}
