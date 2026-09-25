import XCTest
@testable import ClaudioCore

final class UsageTests: XCTestCase {
    let statusLineInput = #"""
    {"session_id":"x","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"subscription_type":"max","rate_limits_available":true,
     "rate_limits":{"five_hour":{"used_percentage":56.2,"resets_at":1790352000},"seven_day":{"used_percentage":7,"resets_at":1790571600}}}
    """#

    func testParsesStatusLineRateLimits() throws {
        let updated = Date(timeIntervalSince1970: 1_790_340_000)
        let usage = try XCTUnwrap(UsageSnapshot.parse(Data(statusLineInput.utf8), updatedAt: updated))
        XCTAssertEqual(usage.fiveHour, UsageWindow(usedPercentage: 56.2, resetsAt: Date(timeIntervalSince1970: 1_790_352_000)))
        XCTAssertEqual(usage.sevenDay?.usedPercentage, 7)
        XCTAssertEqual(usage.subscriptionType, "max")
        XCTAssertEqual(usage.updatedAt, updated)
    }

    func testNoRateLimitsMeansNoSnapshot() {
        XCTAssertNil(UsageSnapshot.parse(Data(#"{"rate_limits_available":false,"rate_limits":null}"#.utf8), updatedAt: Date()))
        XCTAssertNil(UsageSnapshot.parse(Data("garbage".utf8), updatedAt: Date()))
    }

    func testWindowLabels() {
        let now = Date(timeIntervalSince1970: 1_790_340_000)
        let window = UsageWindow(usedPercentage: 56.4, resetsAt: now.addingTimeInterval(2 * 3600 + 5 * 60))
        XCTAssertEqual(window.percentLabel, "56%")
        XCTAssertEqual(window.resetLabel(now: now), "resets in 2h 5m")
        XCTAssertEqual(UsageWindow(usedPercentage: 10, resetsAt: now.addingTimeInterval(3 * 86400 + 3600)).resetLabel(now: now), "resets in 3d 1h")
        XCTAssertEqual(UsageWindow(usedPercentage: 10, resetsAt: now.addingTimeInterval(30)).resetLabel(now: now), "resets in 1m")
        XCTAssertEqual(UsageWindow(usedPercentage: 10, resetsAt: nil).resetLabel(now: now), "")
        XCTAssertEqual(UsageWindow(usedPercentage: 150, resetsAt: nil).fraction, 1)
    }

    func testReadsTheUsersOwnStatusLine() throws {
        let dir = try makeTemporaryDirectory()
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":1}}"#.write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertEqual(UserStatusLine.load(from: settings), UserStatusLine(command: "~/.claude/statusline.sh", padding: 1))
        XCTAssertNil(UserStatusLine.load(from: dir.appendingPathComponent("missing.json")))
    }

    func testStatusLineCaptureRecordsUsageAndRunsTheUsersCommand() throws {
        let dir = try makeTemporaryDirectory()
        let usageFile = dir.appendingPathComponent("usage.json")
        let command = StatusLineCapture(usagePath: usageFile.path, userStatusLine: UserStatusLine(command: "cat >/dev/null; echo 'my status'", padding: nil)).command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(statusLineInput.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "my status\n")
        let recorded = try Data(contentsOf: usageFile)
        XCTAssertEqual(UsageSnapshot.parse(recorded, updatedAt: Date())?.fiveHour?.usedPercentage, 56.2)
    }

    func testSettingsJSONIncludesStatusLineWhenCapturing() throws {
        let capture = StatusLineCapture(usagePath: "/tmp/usage.json", userStatusLine: UserStatusLine(command: "x", padding: 2))
        let json = HookSettings.json(appSessionID: UUID(), eventsPath: "/tmp/h.log", statusLine: capture)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["statusLine"]?["type"], .string("command"))
        XCTAssertEqual(value["statusLine"]?["padding"], .number(2))
        XCTAssertEqual(value["statusLine"]?["refreshInterval"], .number(60))
        XCTAssertNotNil(value["hooks"])
        XCTAssertNil(try JSONDecoder().decode(JSONValue.self, from: Data(HookSettings.json(appSessionID: UUID(), eventsPath: "/x").utf8))["statusLine"])
    }

    func testModelPicksUpUsageFile() throws {
        try MainActor.assumeIsolated {
            let dir = try makeTemporaryDirectory()
            let model = AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: dir),
                                 hookEventsURL: dir.appendingPathComponent("h.log"), usageURL: dir.appendingPathComponent("usage.json"),
                                 locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
            XCTAssertNil(model.usage)
            try statusLineInput.write(to: dir.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)
            model.pollUsage()
            XCTAssertEqual(model.usage?.fiveHour?.usedPercentage, 56.2)
        }
    }
}
