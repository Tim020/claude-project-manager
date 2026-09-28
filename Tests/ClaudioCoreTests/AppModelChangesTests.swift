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

    func testToolWindowsAndDiffs() throws {
        try MainActor.assumeIsolated {
            let home = try makeTemporaryDirectory()
            let (model, id) = try makeModel(home: home, workingDirectory: "/nowhere", runner: FakeRunner())
            XCTAssertEqual(model.toolWindows.visibleLeft, .sessions, "the session tree shows at first")
            XCTAssertNil(model.toolWindows.visibleRight)
            model.toggleTool(.changes)
            XCTAssertEqual(model.toolWindows.visibleRight, .changes)
            XCTAssertEqual(model.settings.toolWindows.visibleRight, .changes, "remembered")
            XCTAssertEqual(model.menuFlags.rightTool, .changes, "the menus follow at once")
            model.toggleTool(.pullRequests)
            XCTAssertEqual(model.menuFlags.leftTool, .pullRequests)

            XCTAssertEqual(model.paneMode(for: id), .terminal)
            XCTAssertNil(model.diffPath(for: id))
            model.openDiff("b.txt", for: id)
            XCTAssertEqual(model.paneMode(for: id), .diff)
            XCTAssertEqual(model.diffPath(for: id), "b.txt", "kept even though no such file is listed")
            model.closeDiff(for: id)
            XCTAssertEqual(model.paneMode(for: id), .terminal)
            XCTAssertNil(model.diffPath(for: id))
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

    func testToolWindowsDecodeWithDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.toolWindows, ToolWindows())
        XCTAssertEqual(decoded.toolWindows.visibleLeft, .sessions)
        XCTAssertNil(decoded.toolWindows.visibleRight)
    }

    func testOpenInspectorBecomesTheChangesTool() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"showFilesInspector":true}"#.utf8))
        XCTAssertEqual(decoded.toolWindows.visibleRight, .changes)
        XCTAssertEqual(decoded.toolWindows.visibleLeft, .sessions)
    }

    func testToolWindowsRoundTrip() throws {
        var settings = AppSettings()
        settings.toolWindows = ToolWindows(left: .pullRequests, isLeftOpen: false, right: .pullRequest, isRightOpen: true)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.toolWindows, settings.toolWindows)
        XCTAssertNil(decoded.toolWindows.visibleLeft, "a hidden side stays hidden")

        let unknown = try JSONDecoder().decode(ToolWindows.self, from: Data(#"{"left":"bookmarks","right":"pullRequest","isRightOpen":true}"#.utf8))
        XCTAssertEqual(unknown.left, .sessions, "a tool from a newer version falls back")
        XCTAssertEqual(unknown.visibleRight, .pullRequest)
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
            model.splitTab(a.id, to: .right, of: model.panes.focusedGroupID)
            XCTAssertEqual(model.visibleSessionIDs, [b.id, a.id], "each pane's shown tab")
        }
    }
}

final class FollowWorktreeTests: XCTestCase {
    func testBothScopesUseTheWorktreeTheSessionWorkedIn() async throws {
        let git = GitChanges.defaultGit
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let root = try makeTemporaryDirectory()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try run(["init", "-q"])
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."]); try run(["commit", "-qm", "base"])
        // Clutter in the main checkout that has nothing to do with the session:
        try "junk\n".write(to: repo.appendingPathComponent("reply_1.txt"), atomically: true, encoding: .utf8)
        // The session's work, in a worktree it created:
        let worktree = repo.appendingPathComponent(".claude/worktrees/fix")
        try run(["worktree", "add", "-q", "-b", "fix", worktree.path])
        let edited = worktree.appendingPathComponent("server/new.py")
        try FileManager.default.createDirectory(at: edited.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "print(1)\n".write(to: edited, atomically: true, encoding: .utf8)

        let home = try makeTemporaryDirectory()
        let sid = "11111111-2222-3333-4444-555555555555"
        let history = SessionDiscovery(claudeHome: home).historyFile(projectPath: repo.path, claudeSessionID: sid)
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"\#(repo.path)","toolUseResult":{"type":"create","filePath":"\#(edited.path)","content":"x","originalFile":null,"structuredPatch":[]}}"#
            .write(to: history, atomically: true, encoding: .utf8)

        let (model, id) = try await MainActor.run { () -> (AppModel, UUID) in
            var state = PersistedState()
            let p = state.workspace.addProject(path: repo.path)
            let session = Session(projectID: p, claudeSessionID: sid, hasConversation: true, name: "s", workingDirectory: repo.path)
            try state.workspace.addSession(session)
            let store = MemoryStore()
            store.state = state
            return (AppModel(store: store, discovery: SessionDiscovery(claudeHome: home), hookEventsURL: home.appendingPathComponent("h.log"),
                             runner: ProcessCommandRunner(), git: git, locateClaude: { _ in nil }, locateGitHubCLI: { nil },
                             shell: "/bin/sh", home: "/"), session.id)
        }
        await model.refreshChanges(for: id)
        await MainActor.run {
            XCTAssertEqual(model.changes(for: id, scope: .session)?.files.map(\.path), ["server/new.py"],
                           "relative to the worktree")
            XCTAssertEqual(model.changes(for: id, scope: .base)?.files.map(\.path), ["server/"],
                           "the worktree's changes, not the main checkout's clutter")
            XCTAssertEqual(model.changesDirectory(for: id).map { ($0 as NSString).lastPathComponent }, "fix")
            XCTAssertEqual(model.workspace.session(id)?.workingDirectory, repo.path, "the session's own folder is unchanged")
        }
    }
}
