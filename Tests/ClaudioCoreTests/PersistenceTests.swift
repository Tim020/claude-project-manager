import XCTest
@testable import ClaudioCore

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
        XCTAssertEqual(state.settings.defaultPermissionMode, .auto)
    }

    /// Settings saved before background agents had their own default keep the
    /// terminal default the user chose, and agents get Auto.
    func testBackgroundPermissionsDefaultToAutoApartFromTheTerminalDefault() throws {
        let json = #"{"version":2,"workspace":{"projects":[],"sessions":[]},"settings":{"defaultPermissionMode":"acceptEdits"}}"#
        let settings = try JSONFileStore.decoder.decode(PersistedState.self, from: Data(json.utf8)).settings
        XCTAssertEqual(settings.defaultPermissionMode(background: false), .acceptEdits)
        XCTAssertEqual(settings.defaultPermissionMode(background: true), .auto)
        var changed = settings
        changed.defaultBackgroundPermissionMode = .plan
        let data = try JSONEncoder().encode(changed)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).defaultBackgroundPermissionMode, .plan)
    }

    func testSessionDecodesOlderFilesWithoutOptionalFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FE","name":"x","workingDirectory":"/","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z"}"#
        let session = try JSONFileStore.decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.tags, [])
        XCTAssertEqual(session.permissionMode, .standard)
        XCTAssertFalse(session.isArchived)
        XCTAssertEqual(session.pullRequests, [])
    }

    /// Earlier versions kept every pull request link a session saw; those
    /// are dropped (discovery finds the ones it acted on again).
    func testOldPullRequestLinksAreDropped() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FE","name":"x","workingDirectory":"/","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z","pullRequestURLs":["https://github.com/other/repo/pull/1"]}"#
        XCTAssertEqual(try JSONFileStore.decoder.decode(Session.self, from: Data(json.utf8)).pullRequests, [])
    }
}

/// A `StateStore` whose `save(_:)` can be made to block on command, so
/// `CoalescingStateStoreTests` can deterministically catch a write while
/// it's in flight rather than racing a real one with sleeps.
private final class SlowFakeStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [PersistedState] = []
    var saved: [PersistedState] { lock.lock(); defer { lock.unlock() }; return _saved }
    /// Signaled once, right when the next `save(_:)` call starts blocking.
    let began = DispatchSemaphore(value: 0)
    /// The next `save(_:)` call waits on this before it's allowed to finish.
    let release = DispatchSemaphore(value: 0)
    private var blockNextSave = false
    var errorToThrow: Error?

    func makeNextSaveBlockUntilReleased() { lock.lock(); blockNextSave = true; lock.unlock() }

    func load() throws -> PersistedState { PersistedState() }

    func save(_ state: PersistedState) throws {
        lock.lock()
        let shouldBlock = blockNextSave
        blockNextSave = false
        lock.unlock()
        if shouldBlock {
            began.signal()
            release.wait()
        }
        lock.lock()
        _saved.append(state)
        lock.unlock()
        if let errorToThrow { throw errorToThrow }
    }
}

/// A lock-protected box, so a background queue's `onError` callback can
/// hand a value back to the test thread without a Sendable-capture warning
/// on a plain `var`.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    func set(_ error: Error) { lock.lock(); value = error; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return value }
}

final class CoalescingStateStoreTests: XCTestCase {
    func state(_ path: String) -> PersistedState {
        var state = PersistedState()
        state.settings.claudePath = path
        return state
    }

    func testBurstOfSavesWhileAWriteIsInFlightCollapsesToTheLastOne() throws {
        let fake = SlowFakeStore()
        let store = CoalescingStateStore(wrapping: fake)
        fake.makeNextSaveBlockUntilReleased()

        try store.save(state("/first"))
        fake.began.wait() // the first write is now blocked inside SlowFakeStore.save

        for i in 0..<5 { try store.save(state("/burst-\(i)")) }
        try store.save(state("/last"))

        fake.release.signal() // let the blocked write finish
        store.flush() // wait for the coalesced write (of whatever's last) too

        XCTAssertEqual(fake.saved.map(\.settings.claudePath), ["/first", "/last"],
                       "the write already in flight, plus one more of whichever state was last set during the burst")
    }

    func testFlushWaitsForTheInFlightWrite() throws {
        let fake = SlowFakeStore()
        let store = CoalescingStateStore(wrapping: fake)
        fake.makeNextSaveBlockUntilReleased()

        try store.save(state("/only"))
        fake.began.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { fake.release.signal() }
        store.flush() // must not return before the release above lets the write finish

        XCTAssertEqual(fake.saved.map(\.settings.claudePath), ["/only"])
    }

    func testWriteErrorReachesOnError() throws {
        let fake = SlowFakeStore()
        fake.errorToThrow = NSError(domain: "CoalescingStateStoreTests", code: 1)
        let store = CoalescingStateStore(wrapping: fake)
        let reported = ErrorBox()
        store.onError = { reported.set($0) }

        try store.save(state("/x"))
        store.flush()

        XCTAssertNotNil(reported.get(), "a failed write isn't silently dropped")
    }
}

final class LegacyDataMigrationTests: XCTestCase {
    func testMovesTheOldSessionManagerFolderOnce() throws {
        let support = try makeTemporaryDirectory()
        let legacy = support.appendingPathComponent("SessionManager")
        let current = support.appendingPathComponent("Claudio")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("state.json"))

        XCTAssertTrue(JSONFileStore.migrateLegacyDirectory(from: legacy, to: current))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("state.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(JSONFileStore.migrateLegacyDirectory(from: legacy, to: current), "nothing left to move")
    }

    func testNeverOverwritesExistingData() throws {
        let support = try makeTemporaryDirectory()
        let legacy = support.appendingPathComponent("SessionManager")
        let current = support.appendingPathComponent("Claudio")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        XCTAssertFalse(JSONFileStore.migrateLegacyDirectory(from: legacy, to: current))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
}
