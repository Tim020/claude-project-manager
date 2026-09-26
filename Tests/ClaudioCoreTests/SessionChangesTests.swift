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
        XCTAssertEqual(result.changes.files.map(\.path), ["Sources/a.swift", "Sources/new.swift", "Sources/gone.swift", "/tmp/outside.txt"])
        XCTAssertEqual(result.changes.files.map(\.status), [.modified, .added, .deleted, .modified])
        XCTAssertEqual(result.changes.files.map(\.additions), [2, 2, 0, 1])
        XCTAssertEqual(result.changes.files.map(\.deletions), [1, 0, 1, 1])
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
