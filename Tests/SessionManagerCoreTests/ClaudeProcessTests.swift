import XCTest
@testable import SessionManagerCore

/// Runs `ClaudeProcess` against a fake `claude` shell script that speaks
/// stream-json, exercising the real pipes, line buffering and exit handling.
final class ClaudeProcessTests: XCTestCase {
    private func makeFakeClaude(_ body: String) throws -> (executable: String, directory: URL) {
        let dir = try makeTemporaryDirectory()
        let url = dir.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, dir)
    }

    private func config(_ executable: String, cwd: URL) -> ClaudeLaunchConfiguration {
        ClaudeLaunchConfiguration(executable: executable, workingDirectory: cwd.path, claudeSessionID: "sid", resume: false,
                                  model: nil, permissionMode: .acceptEdits)
    }

    func testStreamsEventsForAPromptAndReportsExit() throws {
        let fake = try makeFakeClaude("""
        echo "$@" > args.txt
        read line
        echo "$line" > stdin.txt
        echo '{"type":"system","subtype":"init","session_id":"sid","model":"claude-opus-5-5","cwd":"'"$PWD"'"}'
        printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\\n{"type":"result","subtype":"success","is_error":false,"result":"hi"}\\n'
        exit 3
        """)

        let process = ClaudeProcess(configuration: config(fake.executable, cwd: fake.directory), callbackQueue: DispatchQueue(label: "test"))
        let exited = expectation(description: "exit")
        var events: [StreamEvent] = []
        var exitCode: Int32?
        let lock = NSLock()
        process.onEvent = { event in lock.lock(); events.append(event); lock.unlock() }
        process.onExit = { code, _ in exitCode = code; exited.fulfill() }

        try process.start()
        try process.send(StreamInput.userMessage("hello"))
        wait(for: [exited], timeout: 10)

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(exitCode, 3)
        XCTAssertEqual(events.count, 3)
        guard case .initialized(let sessionID, let model, let cwd)? = events.first else { return XCTFail("expected init first") }
        XCTAssertEqual(sessionID, "sid")
        XCTAssertEqual(model, "claude-opus-5-5")
        // macOS reports /var/... as /private/var/..., so compare the directory name.
        XCTAssertEqual(cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, fake.directory.lastPathComponent)
        XCTAssertEqual(events.last, .result(ResultInfo(isError: false, subtype: "success", text: "hi", sessionID: nil, costUSD: nil, permissionDenials: 0)))

        let args = try String(contentsOf: fake.directory.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("--session-id sid"))
        let stdin = try String(contentsOf: fake.directory.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.contains(#""content":"hello""#))
    }

    func testStderrTailIsReportedOnFailure() throws {
        let fake = try makeFakeClaude("""
        echo "Error: not logged in" >&2
        exit 1
        """)
        let process = ClaudeProcess(configuration: config(fake.executable, cwd: fake.directory), callbackQueue: DispatchQueue(label: "test"))
        let exited = expectation(description: "exit")
        var stderr = ""
        process.onExit = { _, tail in stderr = tail; exited.fulfill() }
        try process.start()
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(stderr.trimmingCharacters(in: .whitespacesAndNewlines), "Error: not logged in")
    }

    func testTerminateStopsALongRunningProcess() throws {
        let fake = try makeFakeClaude("exec sleep 30\n")
        let process = ClaudeProcess(configuration: config(fake.executable, cwd: fake.directory), callbackQueue: DispatchQueue(label: "test"))
        let exited = expectation(description: "exit")
        process.onExit = { _, _ in exited.fulfill() }
        try process.start()
        XCTAssertTrue(process.isRunning)
        process.terminate()
        wait(for: [exited], timeout: 10)
        XCTAssertFalse(process.isRunning)
    }

    func testStartingWithMissingExecutableThrows() {
        let process = ClaudeProcess(configuration: config("/definitely/not/here/claude", cwd: FileManager.default.temporaryDirectory))
        XCTAssertThrowsError(try process.start())
    }

    func testSendBeforeStartThrows() {
        let process = ClaudeProcess(configuration: config("/bin/sh", cwd: FileManager.default.temporaryDirectory))
        XCTAssertThrowsError(try process.send("x"))
    }
}
