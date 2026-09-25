import XCTest
@testable import SessionManagerCore

final class ClaudeLaunchTests: XCTestCase {
    func testNewSessionUsesSessionIDFlag() {
        let config = ClaudeLaunchConfiguration(executable: "/usr/local/bin/claude", workingDirectory: "/code",
                                               claudeSessionID: "abc", resume: false, model: "claude-opus-5-5", permissionMode: .acceptEdits)
        XCTAssertEqual(config.arguments, [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--session-id", "abc", "--model", "claude-opus-5-5", "--permission-mode", "acceptEdits",
        ])
    }

    func testExistingSessionResumesAndOmitsDefaultModel() {
        let config = ClaudeLaunchConfiguration(executable: "claude", workingDirectory: "/code",
                                               claudeSessionID: "abc", resume: true, model: nil, permissionMode: .plan)
        XCTAssertEqual(Array(config.arguments.suffix(4)), ["--resume", "abc", "--permission-mode", "plan"])
        XCTAssertFalse(config.arguments.contains("--model"))
    }

    func testConfigurationFromSession() {
        var session = Session(projectID: UUID(), claudeSessionID: "id-1", name: "x", workingDirectory: "/code", model: "opus", permissionMode: .auto)
        var config = ClaudeLaunchConfiguration(session: session, executable: "claude")
        XCTAssertFalse(config.resume)
        XCTAssertEqual(config.model, "opus")
        session.hasConversation = true
        config = ClaudeLaunchConfiguration(session: session, executable: "claude")
        XCTAssertTrue(config.resume)
        XCTAssertEqual(config.workingDirectory, "/code")
        XCTAssertEqual(config.permissionMode, .auto)
    }

    func testUserMessageEncoding() throws {
        let line = try StreamInput.userMessage("Fix \"quotes\"\nand newlines")
        XCTAssertFalse(line.contains("\n"), "must be a single JSON line")
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(decoded["type"], .string("user"))
        XCTAssertEqual(decoded["message"]?["role"], .string("user"))
        XCTAssertEqual(decoded["message"]?["content"], .string("Fix \"quotes\"\nand newlines"))
    }

    func testInterruptEncoding() throws {
        let line = try StreamInput.interrupt(requestID: "r1")
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(decoded["type"], .string("control_request"))
        XCTAssertEqual(decoded["request_id"], .string("r1"))
        XCTAssertEqual(decoded["request"]?["subtype"], .string("interrupt"))
    }
}

final class ClaudeExecutableLocatorTests: XCTestCase {
    func testPrefersExplicitOverride() {
        let found = ClaudeExecutableLocator.locate(override: "/custom/claude", pathVariable: "/usr/bin", home: "/Users/tim",
                                                   isExecutable: { $0 == "/custom/claude" || $0 == "/usr/bin/claude" })
        XCTAssertEqual(found, "/custom/claude")
    }

    func testSearchesPathThenWellKnownLocations() {
        XCTAssertEqual(ClaudeExecutableLocator.locate(override: nil, pathVariable: "/a:/b", home: "/Users/tim",
                                                      isExecutable: { $0 == "/b/claude" }), "/b/claude")
        XCTAssertEqual(ClaudeExecutableLocator.locate(override: nil, pathVariable: "/a", home: "/Users/tim",
                                                      isExecutable: { $0 == "/Users/tim/.claude/local/claude" }), "/Users/tim/.claude/local/claude")
        XCTAssertEqual(ClaudeExecutableLocator.locate(override: nil, pathVariable: nil, home: "/Users/tim",
                                                      isExecutable: { $0 == "/opt/homebrew/bin/claude" }), "/opt/homebrew/bin/claude")
    }

    func testReturnsNilWhenMissingAndIgnoresBlankOverride() {
        XCTAssertNil(ClaudeExecutableLocator.locate(override: "  ", pathVariable: "/a", home: "/h", isExecutable: { _ in false }))
    }

    func testChildEnvironmentAddsExecutableDirectoryAndCommonPaths() {
        let env = ClaudeExecutableLocator.childEnvironment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/tim"], executable: "/Users/tim/.local/bin/claude")
        let path = env["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(path.first, "/Users/tim/.local/bin")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
        XCTAssertEqual(Set(path).count, path.count, "no duplicates")
        XCTAssertEqual(env["HOME"], "/Users/tim")
    }
}
