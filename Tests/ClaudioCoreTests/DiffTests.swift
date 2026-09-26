import XCTest
@testable import ClaudioCore

final class LineDiffTests: XCTestCase {
    private func summary(_ diff: FileDiff) -> [String] {
        diff.lines.map { line in
            switch line.kind {
            case .hunk: return line.text
            case .context: return " \(line.oldNumber!),\(line.newNumber!) \(line.text)"
            case .added: return "+ ,\(line.newNumber!) \(line.text)"
            case .removed: return "- \(line.oldNumber!), \(line.text)"
            }
        }
    }

    func testIdenticalTextHasNoChanges() {
        let diff = LineDiff.diff(old: "a\nb\n", new: "a\nb\n")
        XCTAssertEqual(diff.lines, [])
        XCTAssertEqual(diff.additions, 0)
        XCTAssertEqual(diff.deletions, 0)
    }

    func testModificationWithContextAndLineNumbers() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var newLines = (1...10).map { "line \($0)" }
        newLines[4] = "line five"
        newLines.insert("inserted", at: 7)
        let diff = LineDiff.diff(old: old, new: newLines.joined(separator: "\n") + "\n")
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(summary(diff), [
            "@@ -2,9 +2,10 @@",
            " 2,2 line 2", " 3,3 line 3", " 4,4 line 4",
            "- 5, line 5",
            "+ ,5 line five",
            " 6,6 line 6", " 7,7 line 7",
            "+ ,8 inserted",
            " 8,9 line 8", " 9,10 line 9", " 10,11 line 10",
        ])
    }

    func testDistantChangesMakeSeparateHunks() {
        let old = (1...30).map { "l\($0)" }
        var new = old
        new[1] = "changed 2"
        new[27] = "changed 28"
        let diff = LineDiff.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        XCTAssertEqual(diff.lines.filter { $0.kind == .hunk }.map(\.text), ["@@ -1,5 +1,5 @@", "@@ -25,6 +25,6 @@"])
    }

    func testNewAndDeletedFiles() {
        let added = LineDiff.diff(old: nil, new: "one\ntwo\n")
        XCTAssertEqual(summary(added), ["@@ -0,0 +1,2 @@", "+ ,1 one", "+ ,2 two"])
        let deleted = LineDiff.diff(old: "one\ntwo", new: nil)
        XCTAssertEqual(summary(deleted), ["@@ -1,2 +0,0 @@", "- 1, one", "- 2, two"])
        XCTAssertEqual(deleted.deletions, 2)
    }

    func testLargeRewriteStaysCorrect() {
        let old = (0..<400).map { "a\($0)" }.joined(separator: "\n")
        let new = (0..<400).map { $0 % 3 == 0 ? "b\($0)" : "a\($0)" }.joined(separator: "\n")
        let diff = LineDiff.diff(old: old, new: new)
        XCTAssertEqual(diff.additions, 134)
        XCTAssertEqual(diff.deletions, 134)
    }

    func testBinaryContentIsNotDiffed() {
        let diff = LineDiff.diff(old: "abc", new: "ab\u{0}c")
        XCTAssertTrue(diff.isBinary)
        XCTAssertEqual(diff.lines, [])
    }
}

final class UnifiedDiffParserTests: XCTestCase {
    func testParsesGitDiffOutput() {
        let text = """
        diff --git a/src/app.py b/src/app.py
        index 1111111..2222222 100644
        --- a/src/app.py
        +++ b/src/app.py
        @@ -84,4 +84,5 @@ class Controller:
             async def on_close(self):
        -        await remove(self)
        +        if self.closing:
        +            return
             self.done = True
        \\ No newline at end of file
        """
        let diff = UnifiedDiffParser.parse(text)
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.lines.map(\.kind), [.hunk, .context, .removed, .added, .added, .context])
        XCTAssertEqual(diff.lines[0].text, "@@ -84,4 +84,5 @@ class Controller:")
        XCTAssertEqual(diff.lines[1].oldNumber, 84)
        XCTAssertEqual(diff.lines[2].oldNumber, 85)
        XCTAssertEqual(diff.lines[3].newNumber, 85)
        XCTAssertEqual(diff.lines[5].oldNumber, 86)
        XCTAssertEqual(diff.lines[5].newNumber, 87)
        XCTAssertEqual(diff.lines[2].text, "        await remove(self)")
    }

    func testBinaryAndEmpty() {
        XCTAssertTrue(UnifiedDiffParser.parse("diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n").isBinary)
        XCTAssertEqual(UnifiedDiffParser.parse(""), FileDiff.empty)
    }
}

final class ChangeSetTests: XCTestCase {
    func testSummaryCountsAndBlocks() {
        let set = ChangeSet(files: [
            FileChange(path: "a/one.swift", status: .modified, additions: 48, deletions: 12),
            FileChange(path: "a/two.swift", status: .added, additions: 10, deletions: 0),
            FileChange(path: "b/three.swift", status: .deleted, additions: 0, deletions: 61),
            FileChange(path: "four.swift", oldPath: "old/four.swift", status: .renamed, additions: 2, deletions: 1),
        ])
        XCTAssertEqual(set.additions, 60)
        XCTAssertEqual(set.deletions, 74)
        XCTAssertEqual(set.count(.modified), 1)
        XCTAssertEqual(set.count(.renamed), 1)
        XCTAssertEqual(ChangeBlocks.blocks(additions: 379, deletions: 96), [true, true, true, true, false])
        XCTAssertEqual(ChangeBlocks.blocks(additions: 0, deletions: 0), [false, false, false, false, false])
        XCTAssertEqual(set.files[0].name, "one.swift")
        XCTAssertEqual(set.files[0].directory, "a")
        XCTAssertEqual(set.files[3].directory, "")
        XCTAssertEqual(FileChangeStatus.renamed.word, "Renamed")
        XCTAssertEqual(FileChangeStatus.deleted.letter, "D")
    }

    func testGroupsByDirectoryInOrder() {
        let set = ChangeSet(files: [
            FileChange(path: "server/ws/a.py", status: .modified, additions: 1, deletions: 0),
            FileChange(path: "client/b.ts", status: .modified, additions: 1, deletions: 0),
            FileChange(path: "server/ws/c.py", status: .added, additions: 1, deletions: 0),
        ])
        XCTAssertEqual(set.groupedByDirectory.map(\.directory), ["server/ws", "client"])
        XCTAssertEqual(set.groupedByDirectory[0].files.map(\.name), ["a.py", "c.py"])
    }
}
