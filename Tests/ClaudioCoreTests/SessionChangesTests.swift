import XCTest
@testable import ClaudioCore

/// "This Session": files changed by the session's Edit/Write tool calls.
/// Record shapes recorded from Claude Code transcripts (toolUseResult).
final class SessionChangesTests: XCTestCase {
    let dir = "/Users/tim/Code/app/.claude/worktrees/fix"

    private func edit(_ path: String, original: String?) -> String {
        let originalJSON = original.map { "\"\(escape($0))\"" } ?? "null"
        return #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]},"toolUseResult":{"filePath":"\#(path)","oldString":"a","newString":"b","originalFile":\#(originalJSON),"structuredPatch":[],"userModified":false,"replaceAll":false}}"#
    }

    private func write(_ path: String, kind: String, original: String?) -> String {
        let originalJSON = original.map { "\"\(escape($0))\"" } ?? "null"
        return #"{"type":"user","toolUseResult":{"type":"\#(kind)","filePath":"\#(path)","content":"x","originalFile":\#(originalJSON),"structuredPatch":[],"userModified":false}}"#
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }

    func testFirstBaselinePerFileInOrder() {
        let lines = [
            edit("\(dir)/Sources/a.swift", original: "one\n"),
            write("\(dir)/Sources/new.swift", kind: "create", original: nil),
            edit("\(dir)/Sources/a.swift", original: "one changed\n"),   // later edit: keep the first baseline
            #"{"type":"user","toolUseResult":{"stdout":"ok","stderr":""}}"#,  // Bash result
            write("\(dir)/README.md", kind: "update", original: "old readme\n"),
        ]
        let baselines = SessionEditLog.baselines(lines: lines)
        XCTAssertEqual(baselines.map(\.path), ["\(dir)/Sources/a.swift", "\(dir)/Sources/new.swift", "\(dir)/README.md"])
        XCTAssertEqual(baselines.map(\.original), ["one\n", nil, "old readme\n"])
    }

    func testChangesCompareFirstBaselineWithDisk() {
        let baselines = [
            SessionEditLog.Baseline(path: "\(dir)/Sources/a.swift", original: "one\ntwo\nthree\n"),
            SessionEditLog.Baseline(path: "\(dir)/Sources/new.swift", original: nil),
            SessionEditLog.Baseline(path: "\(dir)/Sources/gone.swift", original: "bye\n"),
            SessionEditLog.Baseline(path: "\(dir)/Sources/reverted.swift", original: "same\n"),
            SessionEditLog.Baseline(path: "\(dir)/Sources/tmp.swift", original: nil),
            SessionEditLog.Baseline(path: "/tmp/outside.txt", original: "x\n"),
        ]
        let disk: [String: String] = [
            "\(dir)/Sources/a.swift": "one\n2\nthree\nfour\n",
            "\(dir)/Sources/new.swift": "hello\nworld\n",
            "\(dir)/Sources/reverted.swift": "same\n",
            "/tmp/outside.txt": "y\n",
        ]
        let result = SessionChanges.compute(baselines: baselines, workingDirectory: dir, read: { disk[$0] })
        XCTAssertEqual(result.changes.files.map(\.path), ["Sources/a.swift", "Sources/new.swift", "Sources/gone.swift"],
                       "unchanged, never-existing and outside-the-folder files are left out")
        XCTAssertEqual(result.changes.files.map(\.status), [.modified, .added, .deleted])
        XCTAssertEqual(result.changes.files.map(\.additions), [2, 2, 0])
        XCTAssertEqual(result.changes.files.map(\.deletions), [1, 0, 1])
        XCTAssertEqual(result.diffs["Sources/a.swift"]?.additions, 2)
        XCTAssertEqual(result.absolutePaths["Sources/a.swift"], "\(dir)/Sources/a.swift")
    }

    func testReadsTheSessionAndItsSubagentTranscripts() throws {
        let home = try makeTemporaryDirectory()
        let discovery = SessionDiscovery(claudeHome: home)
        let sid = "11111111-2222-3333-4444-555555555555"
        let main = discovery.historyFile(projectPath: dir, claudeSessionID: sid)
        try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        try edit("\(dir)/a.swift", original: "a\n").write(to: main, atomically: true, encoding: .utf8)
        let subagents = main.deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try write("\(dir)/b.swift", kind: "create", original: nil).write(to: subagents.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)

        let files = discovery.editLogFiles(projectPath: dir, claudeSessionID: sid)
        XCTAssertEqual(files.map(\.lastPathComponent), ["\(sid).jsonl", "agent-1.jsonl"])
        let baselines = SessionEditLog.baselines(files: files)
        XCTAssertEqual(baselines.map(\.path), ["\(dir)/a.swift", "\(dir)/b.swift"])
    }

    func testTooLargeOrBinaryFilesAreListedWithoutADiff() {
        let result = SessionChanges.compute(baselines: [SessionEditLog.Baseline(path: "\(dir)/img.png", original: "a")],
                                            workingDirectory: dir, read: { _ in "b\u{0}" })
        XCTAssertEqual(result.changes.files.first?.isBinary, true)
        XCTAssertEqual(result.diffs["img.png"]?.isBinary, true)
    }
}

final class SessionChangesScopeTests: XCTestCase {
    func testOnlyFilesInTheSessionOrProjectFolderCount() {
        let repo = "/Users/tim/Code/app"
        let worktree = "/Users/tim/Code/app/.claude/worktrees/fix"
        let paths = [
            "\(worktree)/Sources/a.swift",                     // the session's worktree
            "\(repo)/CLAUDE.md",                                // the project itself
            "\(repo)/.claude/settings.json",                    // project config: real project files
            "\(repo)/.claude/worktrees/other/b.swift",          // another session's worktree
            "/Users/tim/.claude/plans/plan.md",                 // Claude Code's own files
            "/tmp/scratch.py",                                  // scratch files
            "/Users/tim/Code/app-other/c.swift",                // a sibling folder with a shared prefix
        ]
        let baselines = paths.map { SessionEditLog.Baseline(path: $0, original: "old\n") }
        let result = SessionChanges.compute(baselines: baselines, workingDirectory: worktree, projectDirectory: repo,
                                            read: { _ in "new\n" })
        XCTAssertEqual(result.changes.files.map(\.path), ["Sources/a.swift", "/Users/tim/Code/app/CLAUDE.md", "/Users/tim/Code/app/.claude/settings.json"])
    }

    func testPathsAreComparedAfterStandardising() {
        let result = SessionChanges.compute(baselines: [SessionEditLog.Baseline(path: "/Users/tim/Code/app/./src/../src/x.swift", original: "a\n")],
                                            workingDirectory: "/Users/tim/Code/app/", projectDirectory: nil, read: { _ in "b\n" })
        XCTAssertEqual(result.changes.files.map(\.path), ["src/x.swift"])
    }
}

/// A session can work somewhere other than the folder it started in (Claude
/// entered a worktree, or a subagent worked in one); Files Changed follows it.
final class ChangesDirectoryTests: XCTestCase {
    let repo = "/Users/tim/Code/DigiScript"

    func testLogSummaryHasTheLatestEditAndWorkingDirectory() {
        let lines = [
            #"{"type":"user","cwd":"/Users/tim/Code/DigiScript","message":{"content":"go"}}"#,
            #"{"type":"user","cwd":"/Users/tim/Code/DigiScript","toolUseResult":{"type":"create","filePath":"/Users/tim/Code/DigiScript/.claude/worktrees/fix/a.py","content":"x","originalFile":null,"structuredPatch":[]}}"#,
            #"{"type":"assistant","cwd":"/Users/tim/Code/DigiScript/.claude/worktrees/fix/server","message":{"content":[]}}"#,
        ]
        let summary = SessionEditLog.summary(lines: lines)
        XCTAssertEqual(summary.baselines.map(\.path), ["\(repo)/.claude/worktrees/fix/a.py"])
        XCTAssertEqual(summary.lastEditPath, "\(repo)/.claude/worktrees/fix/a.py")
        XCTAssertEqual(summary.lastWorkingDirectory, "\(repo)/.claude/worktrees/fix/server")
    }

    func testTheWorktreeOfTheLatestEditWins() {
        let dir = ChangesDirectory.resolve(recorded: repo, projectDirectory: repo,
                                           lastWorkingDirectory: repo,
                                           recentEdits: ["\(repo)/.claude/worktrees/fix-ws-reconnect/server/utils/web/a.py"],
                                           exists: { _ in true })
        XCTAssertEqual(dir, "\(repo)/.claude/worktrees/fix-ws-reconnect")
    }

    func testThenTheLastWorkingDirectoryInsideTheProject() {
        let dir = ChangesDirectory.resolve(recorded: repo, projectDirectory: repo,
                                           lastWorkingDirectory: "\(repo)/server", recentEdits: ["\(repo)/server/app.py"],
                                           exists: { _ in true })
        XCTAssertEqual(dir, "\(repo)/server")
    }

    func testIgnoresPlacesOutsideTheProjectOrGone() {
        XCTAssertEqual(ChangesDirectory.resolve(recorded: repo, projectDirectory: repo, lastWorkingDirectory: "/tmp",
                                                recentEdits: ["/tmp/scratch.py"], exists: { _ in true }), repo, "cd /tmp")
        XCTAssertEqual(ChangesDirectory.resolve(recorded: repo, projectDirectory: repo, lastWorkingDirectory: nil,
                                                recentEdits: ["\(repo)/.claude/worktrees/removed/a.py"],
                                                exists: { !$0.contains("removed") }), repo, "worktree since removed")
        XCTAssertEqual(ChangesDirectory.resolve(recorded: repo, projectDirectory: nil, lastWorkingDirectory: nil,
                                                recentEdits: [], exists: { _ in true }), repo)
    }

    /// The main session's last edit was a plan under ~/.claude; its subagent
    /// has since edited a worktree. The ~/.claude edit doesn't count.
    func testEditsOutsideTheProjectAreSkipped() {
        let dir = ChangesDirectory.resolve(recorded: repo, projectDirectory: repo, lastWorkingDirectory: repo,
                                           recentEdits: ["/Users/tim/.claude/plans/plan.md", "/tmp/x.txt",
                                                         "\(repo)/.claude/worktrees/fix-ws/server/a.py"],
                                           exists: { _ in true })
        XCTAssertEqual(dir, "\(repo)/.claude/worktrees/fix-ws")
    }

    func testANewerEditInTheMainCheckoutWins() {
        let dir = ChangesDirectory.resolve(recorded: repo, projectDirectory: repo, lastWorkingDirectory: repo,
                                           recentEdits: ["\(repo)/server/app.py", "\(repo)/.claude/worktrees/fix-ws/a.py"],
                                           exists: { _ in true })
        XCTAssertEqual(dir, repo)
    }

    func testSkipsRemovedWorktreesForAnOlderOne() {
        let dir = ChangesDirectory.resolve(recorded: repo, projectDirectory: repo, lastWorkingDirectory: nil,
                                           recentEdits: ["\(repo)/.claude/worktrees/gone/a.py", "\(repo)/.claude/worktrees/kept/b.py"],
                                           exists: { !$0.contains("gone") })
        XCTAssertEqual(dir, "\(repo)/.claude/worktrees/kept")
    }

    func testEditsAreOrderedByTimestampAcrossHistories() {
        let main = [SessionEditLog.Edit(path: "\(repo)/server/app.py", timestamp: "2026-09-25T10:00:00.000Z"),
                    SessionEditLog.Edit(path: "/Users/tim/.claude/plans/p.md", timestamp: "2026-09-25T12:00:00.000Z")]
        let subagent = [SessionEditLog.Edit(path: "\(repo)/.claude/worktrees/fix/a.py", timestamp: "2026-09-25T11:00:00.000Z"),
                        SessionEditLog.Edit(path: "\(repo)/untimed.py")]
        XCTAssertEqual(SessionEditLog.Summary.pathsNewestFirst(main + subagent),
                       ["/Users/tim/.claude/plans/p.md", "\(repo)/.claude/worktrees/fix/a.py", "\(repo)/server/app.py", "\(repo)/untimed.py"])
    }

    func testLogSummaryRecordsEachFilesLatestEditTime() {
        let edit = { (path: String, time: String) in
            #"{"type":"user","timestamp":"\#(time)","toolUseResult":{"type":"update","filePath":"\#(path)","content":"x","originalFile":"y","structuredPatch":[]}}"#
        }
        let summary = SessionEditLog.summary(lines: [edit("/a", "2026-09-25T10:00:00Z"), edit("/b", "2026-09-25T11:00:00Z"),
                                                     edit("/a", "2026-09-25T12:00:00Z")])
        XCTAssertEqual(summary.edits, [SessionEditLog.Edit(path: "/b", timestamp: "2026-09-25T11:00:00Z"),
                                       SessionEditLog.Edit(path: "/a", timestamp: "2026-09-25T12:00:00Z")])
        XCTAssertEqual(summary.lastEditPath, "/a")
    }
}
