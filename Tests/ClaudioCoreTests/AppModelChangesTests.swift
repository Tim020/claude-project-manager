import XCTest
@testable import ClaudioCore

final class AppModelChangesTests: XCTestCase {
    let sid = "11111111-2222-3333-4444-555555555555"

    private func record(_ path: String, original: String?) -> String {
        let originalJSON = original.map { "\"\($0.replacingOccurrences(of: "\n", with: "\\n"))\"" } ?? "null"
        return #"{"type":"user","toolUseResult":{"type":"\#(original == nil ? "create" : "update")","filePath":"\#(path)","content":"x","originalFile":\#(originalJSON),"structuredPatch":[]}}"#
    }

    @MainActor private func makeModel(home: URL, workingDirectory: String, runner: CommandRunning = ProcessCommandRunner()) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: workingDirectory)
        let session = Session(projectID: p, claudeSessionID: sid, hasConversation: true, name: "s", workingDirectory: workingDirectory)
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: home),
                             hookEventsURL: home.appendingPathComponent("hooks.log"), runner: runner,
                             locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
        return (model, session.id)
    }

    func testThisSessionScopeFromTheHistory() async throws {
        let home = try makeTemporaryDirectory()
        let work = try makeTemporaryDirectory().appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "one\nTWO\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: work.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let history = SessionDiscovery(claudeHome: home).historyFile(projectPath: work.path, claudeSessionID: sid)
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try [record(work.appendingPathComponent("a.txt").path, original: "one\ntwo\n"),
             record(work.appendingPathComponent("b.txt").path, original: nil)].joined(separator: "\n")
            .write(to: history, atomically: true, encoding: .utf8)

        let (model, id) = try await MainActor.run { try makeModel(home: home, workingDirectory: work.path) }
        await model.refreshChanges(for: id)
        let set = try await MainActor.run { try XCTUnwrap(model.changes(for: id, scope: .session)) }
        XCTAssertEqual(set.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(set.files.map(\.status), [.modified, .added])
        let diff = await model.diff(for: id, path: "a.txt", scope: .session)
        XCTAssertEqual(diff?.additions, 1)
        await MainActor.run {
            XCTAssertEqual(model.absolutePath(for: id, path: "b.txt", scope: .session), work.appendingPathComponent("b.txt").path)
            XCTAssertEqual(model.baseUnavailableReason(for: id), "This session's folder isn't in a git repository.")
            XCTAssertNil(model.changes(for: id, scope: .base))
        }
    }

    func testVsMainScopeFromGit() async throws {
        let git = GitChanges.defaultGit
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let home = try makeTemporaryDirectory()
        let repo = try makeTemporaryDirectory().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try run(["init", "-q"])
        try "a\nb\n".write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."]); try run(["commit", "-qm", "base"]); try run(["checkout", "-qb", "work"])
        try "a\nB\n".write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)

        let (model, id) = try await MainActor.run { try makeModel(home: home, workingDirectory: repo.path) }
        await model.refreshChanges(for: id)
        await MainActor.run {
            XCTAssertEqual(model.baseName(for: id), "main")
            XCTAssertNil(model.baseUnavailableReason(for: id))
            XCTAssertEqual(model.changes(for: id, scope: .base)?.files.map(\.path), ["x.txt"])
            XCTAssertEqual(model.changes(for: id, scope: .session), .empty, "no history, no session edits")
        }
        let diff = await model.diff(for: id, path: "x.txt", scope: .base)
        XCTAssertEqual(diff?.additions, 1)
        await MainActor.run { XCTAssertNotNil(model.sessionChanges[id]?.gitDiffs["x.txt"], "kept for next time") }
    }

    func testViewStateAndOpenFullDiff() throws {
        try MainActor.assumeIsolated {
            let home = try makeTemporaryDirectory()
            let (model, id) = try makeModel(home: home, workingDirectory: "/nowhere", runner: FakeRunner())
            XCTAssertFalse(model.showsFilesInspector)
            model.toggleFilesInspector()
            XCTAssertTrue(model.showsFilesInspector)
            XCTAssertTrue(model.settings.showFilesInspector, "remembered")

            XCTAssertEqual(model.paneMode(for: id), .terminal)
            model.toggleExpandedChange("a.txt", for: id)
            XCTAssertEqual(model.expandedChange(for: id), "a.txt")
            model.toggleExpandedChange("a.txt", for: id)
            XCTAssertNil(model.expandedChange(for: id))

            model.openFullDiff("b.txt", for: id)
            XCTAssertEqual(model.paneMode(for: id), .changes)
            model.setPaneMode(.terminal, for: id)
            XCTAssertEqual(model.paneMode(for: id), .terminal)
        }
    }

    func testHookToolCallsMarkChangesForRefresh() async throws {
        let home = try makeTemporaryDirectory()
        let runner = FakeRunner()
        let (model, id) = try await MainActor.run { try makeModel(home: home, workingDirectory: "/nowhere", runner: runner) }
        await model.refreshChangesIfNeeded([id])
        let first = runner.commands.count
        XCTAssertGreaterThan(first, 0, "never loaded, so loaded")
        await model.refreshChangesIfNeeded([id])
        XCTAssertEqual(runner.commands.count, first, "nothing new, so not reloaded")

        let line = "\(id.uuidString)\t" + #"{"hook_event_name":"PostToolUse","session_id":"\#(sid)","tool_name":"Edit"}"# + "\n"
        let handle = try FileHandle(forWritingTo: { () -> URL in
            let url = home.appendingPathComponent("hooks.log")
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            return url
        }())
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)); try handle.close()
        await MainActor.run { model.pollHookEvents() }
        await model.refreshChangesIfNeeded([id])
        XCTAssertGreaterThan(runner.commands.count, first, "a tool call triggers a reload")
    }

    func testSettingDecodesWithDefault() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.showFilesInspector)
    }
}

final class VisibleSessionTests: XCTestCase {
    func testVisibleSessionsFollowTheLayout() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            let a = Session(projectID: p, name: "a", workingDirectory: "/code")
            let b = Session(projectID: p, name: "b", workingDirectory: "/code")
            try state.workspace.addSession(a)
            try state.workspace.addSession(b)
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            XCTAssertEqual(model.visibleSessionIDs, [])
            model.select(a.id)
            model.select(b.id)
            XCTAssertEqual(model.visibleSessionIDs, [b.id])
            model.setLayout(.split)
            XCTAssertEqual(Set(model.visibleSessionIDs), [a.id, b.id])
        }
    }
}
