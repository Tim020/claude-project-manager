import XCTest
@testable import ClaudioCore

final class ShellQuoteTests: XCTestCase {
    func testQuotesForPOSIXShells() {
        XCTAssertEqual(ShellQuote.quote("plain"), "'plain'")
        XCTAssertEqual(ShellQuote.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellQuote.quote(""), "''")
        XCTAssertEqual(ShellQuote.quote("$HOME `x` \"y\""), #"'$HOME `x` "y"'"#)
    }

    func testQuotedStringsSurviveARealShell() throws {
        let tricky = ["it's", "$HOME", "a b", "\"q\"", "new\nline", "back\\slash", "*"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\0' " + tricky.map(ShellQuote.quote).joined(separator: " ")]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(output.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init), tricky)
    }
}

final class HookSettingsTests: XCTestCase {
    func testRegistersEveryEventWithTaggedAppendCommand() throws {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
        let json = HookSettings.json(appSessionID: id, eventsPath: "/Users/tim/Library/Application Support/SessionManager/hook-events.log")
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let hooks = try XCTUnwrap(value["hooks"]?.objectValue)
        XCTAssertEqual(Set(hooks.keys), Set(HookSettings.events.map(\.rawValue)))
        let command = try XCTUnwrap(hooks["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue)
        XCTAssertEqual(hooks["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["type"], .string("command"))
        XCTAssertTrue(command.contains(id.uuidString))
        XCTAssertTrue(command.contains("'/Users/tim/Library/Application Support/SessionManager/hook-events.log'"))
    }

    func testHookCommandWritesParsableLine() throws {
        let dir = try makeTemporaryDirectory()
        let log = dir.appendingPathComponent("it's events.log")
        let id = UUID()
        let json = HookSettings.json(appSessionID: id, eventsPath: log.path)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let command = try XCTUnwrap(value["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue)

        // Claude Code runs hook commands with the event JSON on stdin.
        for _ in 0..<2 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"abc","last_assistant_message":"a\nb"}"#.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        var tailer = HookEventTailer(url: log)
        let events = tailer.readNew()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.appSessionID, id)
        XCTAssertEqual(events.first?.lastAssistantMessage, "a\nb")
    }
}

final class TerminalLaunchTests: XCTestCase {
    let appID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!

    private func session(hasConversation: Bool = false, mode: PermissionMode = .standard, model: String? = nil) -> Session {
        Session(id: appID, projectID: UUID(), claudeSessionID: "abc", hasConversation: hasConversation, name: "s",
                workingDirectory: "/Users/tim/My Code/app", model: model, permissionMode: mode)
    }

    private func make(_ session: Session, prompt: String? = nil) -> TerminalLaunch {
        TerminalLaunch.make(session: session, claudeExecutable: "/Users/tim/.local/bin/claude", shell: "/bin/zsh",
                            initialPrompt: prompt, hookEventsPath: "/tmp/events.log",
                            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/tim", "TERM": "dumb"])
    }

    func testNewSessionArguments() {
        let launch = make(session(mode: .acceptEdits, model: "claude-opus-5-5"), prompt: "Fix the bug")
        XCTAssertEqual(Array(launch.claudeArguments.prefix(7)), [
            "Fix the bug", "--session-id", "abc", "--model", "claude-opus-5-5", "--permission-mode", "acceptEdits",
        ])
        XCTAssertEqual(launch.claudeArguments[7], "--settings")
        XCTAssertEqual(launch.claudeArguments.count, 9)
    }

    func testResumeOmitsDefaultsAndPrompt() {
        let launch = make(session(hasConversation: true), prompt: "  ")
        XCTAssertEqual(Array(launch.claudeArguments.prefix(2)), ["--resume", "abc"])
        XCTAssertFalse(launch.claudeArguments.contains("--permission-mode"))
        XCTAssertFalse(launch.claudeArguments.contains("--model"))
    }

    func testRunsThroughLoginShellInWorkingDirectory() {
        let launch = make(session(), prompt: "it's done?")
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(Array(launch.arguments.prefix(2)), ["-l", "-c"])
        let command = launch.arguments[2]
        XCTAssertTrue(command.hasPrefix("cd '/Users/tim/My Code/app' && exec '/Users/tim/.local/bin/claude' 'it'\\''s done?' "))
        XCTAssertEqual(launch.workingDirectory, "/Users/tim/My Code/app")
    }

    func testEnvironmentIsTerminalFriendly() {
        let env = make(session()).environment
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["CLAUDIO_SESSION_ID"], appID.uuidString)
        XCTAssertEqual(env["PATH"]?.split(separator: ":").first, "/Users/tim/.local/bin")
        XCTAssertEqual(env["HOME"], "/Users/tim")
        XCTAssertTrue(make(session()).environmentList.contains("TERM=xterm-256color"))
    }

    func testSessionWithoutClaudeIDUsesItsOwnID() {
        var s = session()
        s.claudeSessionID = nil
        XCTAssertEqual(Array(make(s).claudeArguments.prefix(2)), ["--session-id", appID.uuidString.lowercased()])
    }

    func testCommandRunsInARealShell() throws {
        let dir = try makeTemporaryDirectory().appendingPathComponent("it's here")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("claude")
        try "#!/bin/sh\npwd > out.txt\nprintf '%s\\n' \"$@\" >> out.txt\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        var s = session()
        s.workingDirectory = dir.path
        let launch = TerminalLaunch.make(session: s, claudeExecutable: fake.path, shell: "/bin/sh", initialPrompt: "say \"hi\"",
                                         hookEventsPath: "/tmp/x.log", baseEnvironment: ProcessInfo.processInfo.environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments.filter { $0 != "-l" }
        try process.run()
        process.waitUntilExit()

        let lines = try String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix("it's here"))
        XCTAssertEqual(lines[1], "say \"hi\"")
        XCTAssertEqual(lines[2], "--session-id")
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

    func testDefaultShellComesFromEnvironment() {
        XCTAssertEqual(ClaudeExecutableLocator.defaultShell(environment: ["SHELL": "/opt/homebrew/bin/fish"]), "/opt/homebrew/bin/fish")
        XCTAssertEqual(ClaudeExecutableLocator.defaultShell(environment: [:]), "/bin/zsh")
    }
}
