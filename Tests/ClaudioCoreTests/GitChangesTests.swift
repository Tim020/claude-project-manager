import XCTest
@testable import ClaudioCore

final class GitOutputParsingTests: XCTestCase {
    func testMergesNumstatAndNameStatus() {
        // `git diff -M -z --numstat` and `--name-status` for the same diff.
        let numstat = "48\t12\tserver/ws/sessions.py\u{0}142\t0\tserver/test/test_close.py\u{0}0\t61\tclient/wsReconnect.ts\u{0}22\t5\t\u{0}client/utils/socket.ts\u{0}client/composables/useSocket.ts\u{0}-\t-\tassets/logo.png\u{0}"
        let nameStatus = "M\u{0}server/ws/sessions.py\u{0}A\u{0}server/test/test_close.py\u{0}D\u{0}client/wsReconnect.ts\u{0}R087\u{0}client/utils/socket.ts\u{0}client/composables/useSocket.ts\u{0}M\u{0}assets/logo.png\u{0}"
        let files = GitChanges.parse(numstat: numstat, nameStatus: nameStatus)
        XCTAssertEqual(files, [
            FileChange(path: "server/ws/sessions.py", status: .modified, additions: 48, deletions: 12),
            FileChange(path: "server/test/test_close.py", status: .added, additions: 142, deletions: 0),
            FileChange(path: "client/wsReconnect.ts", status: .deleted, additions: 0, deletions: 61),
            FileChange(path: "client/composables/useSocket.ts", oldPath: "client/utils/socket.ts", status: .renamed, additions: 22, deletions: 5),
            FileChange(path: "assets/logo.png", status: .modified, additions: 0, deletions: 0, isBinary: true),
        ])
    }

    func testBaseBranchNames() {
        XCTAssertEqual(GitChanges.displayName(ofBase: "origin/main"), "main")
        XCTAssertEqual(GitChanges.displayName(ofBase: "origin/dev"), "dev")
        XCTAssertEqual(GitChanges.displayName(ofBase: "master"), "master")
    }
}

/// Runs real git in a temporary repository.
final class GitChangesIntegrationTests: XCTestCase {
    let runner = ProcessCommandRunner()
    var git: String { ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git" }

    @discardableResult
    private func run(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func file(_ dir: URL, _ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeRepo() throws -> URL {
        let dir = try makeTemporaryDirectory().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["init", "-q"], in: dir)
        try file(dir, "src/app.py", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try file(dir, "src/old_name.py", "a\nb\nc\nd\ne\nf\n")
        try file(dir, "README.md", "readme\n")
        try run(["add", "."], in: dir)
        try run(["commit", "-qm", "base"], in: dir)
        try run(["checkout", "-qb", "feature"], in: dir)
        return dir
    }

    func testChangesAgainstTheBaseBranchIncludeCommittedUncommittedAndUntracked() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let dir = try makeRepo()
        // Committed on the branch:
        var app = (1...20).map { "line \($0)" }
        app[4] = "line five"
        try file(dir, "src/app.py", app.joined(separator: "\n") + "\n")
        try run(["mv", "src/old_name.py", "src/new_name.py"], in: dir)
        try run(["commit", "-qam", "work"], in: dir)
        // Uncommitted:
        try FileManager.default.removeItem(at: dir.appendingPathComponent("README.md"))
        try file(dir, "notes/todo.txt", "one\ntwo\nthree\n")

        let result = try await GitChanges.load(directory: dir.path, runner: runner, git: git).get()
        XCTAssertEqual(result.baseName, "main")
        let byPath = Dictionary(uniqueKeysWithValues: result.changes.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["src/app.py"]?.status, .modified)
        XCTAssertEqual(byPath["src/app.py"]?.additions, 1)
        XCTAssertEqual(byPath["src/new_name.py"]?.status, .renamed)
        XCTAssertEqual(byPath["src/new_name.py"]?.oldPath, "src/old_name.py")
        XCTAssertEqual(byPath["README.md"]?.status, .deleted)
        XCTAssertEqual(byPath["notes/todo.txt"]?.status, .added)
        XCTAssertEqual(byPath["notes/todo.txt"]?.additions, 3)

        let appDiff = await GitChanges.diff(for: try XCTUnwrap(byPath["src/app.py"]), in: result, runner: runner, git: git)
        XCTAssertEqual(appDiff.additions, 1)
        XCTAssertEqual(appDiff.lines.first { $0.kind == .added }?.text, "line five")
        let untracked = await GitChanges.diff(for: try XCTUnwrap(byPath["notes/todo.txt"]), in: result, runner: runner, git: git)
        XCTAssertEqual(untracked.additions, 3)
        // git reports the real path (/private/var/… on macOS), so check it points at the file.
        let absolute = result.absolutePath(for: try XCTUnwrap(byPath["notes/todo.txt"]))
        XCTAssertTrue(absolute.hasSuffix("/repo/notes/todo.txt"), absolute)
        XCTAssertEqual(try String(contentsOfFile: absolute, encoding: .utf8), "one\ntwo\nthree\n")
    }

    func testFromASubdirectoryAndWithoutChanges() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let dir = try makeRepo()
        let result = try await GitChanges.load(directory: dir.appendingPathComponent("src").path, runner: runner, git: git).get()
        XCTAssertTrue(result.changes.isEmpty)
    }

    func testNotARepository() async throws {
        let dir = try makeTemporaryDirectory()
        let result = await GitChanges.load(directory: dir.path, runner: runner, git: git)
        XCTAssertEqual(result, .failure(.notARepository))
    }

    func testNoBaseBranch() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let dir = try makeRepo()
        try run(["branch", "-qm", "main", "trunk-only"], in: dir)
        let result = await GitChanges.load(directory: dir.path, runner: runner, git: git)
        XCTAssertEqual(result, .failure(.noBaseBranch))
    }
}
