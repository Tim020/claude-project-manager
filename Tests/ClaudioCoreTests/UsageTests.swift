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

/// `claude -p /usage --output-format stream-json --verbose`, recorded from
/// 2.1.283 (ids and credit amounts changed, hook and behaviour lines trimmed).
final class UsageCreditsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_380_000)

    func testParsesTheUsageReport() throws {
        let usage = try XCTUnwrap(UsageSnapshot.parseUsageStream(try Fixtures.string("usage-stream.jsonl"), updatedAt: now))
        XCTAssertEqual(usage.fiveHour?.usedPercentage, 5)
        XCTAssertEqual(usage.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_790_480_999), "2026-09-27T03:49:59Z")
        XCTAssertEqual(usage.sevenDay?.usedPercentage, 42)
        XCTAssertEqual(usage.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_790_571_599))
        XCTAssertEqual(usage.credits, UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 1250, utilization: 25, currency: "GBP"))
        XCTAssertFalse(usage.reportsUsingCredits)
        XCTAssertFalse(usage.isUsingCredits, "no plan limit is reached")
        XCTAssertEqual(usage.updatedAt, now)
    }

    func testFallsBackToTheTextWithoutAReport() throws {
        let text = "You are currently using your overages to power your Claude Code usage. We will automatically switch you back to your subscription rate limits when they reset\n\nCurrent session: 100% used · resets 5pm"
        let data = try JSONEncoder().encode(JSONValue.object(["type": .string("result"), "result": .string(text)]))
        let usage = try XCTUnwrap(UsageSnapshot.parseUsageStream(String(decoding: data, as: UTF8.self), updatedAt: now))
        XCTAssertEqual(usage.fiveHour?.usedPercentage, 100)
        XCTAssertTrue(usage.reportsUsingCredits)
        XCTAssertNil(usage.credits)
        XCTAssertFalse(usage.isUsingCredits, "credits aren't known to be enabled")
        XCTAssertNil(UsageSnapshot.parseUsageStream("Current session: 5% used", updatedAt: now), "plain text isn't stream JSON")
    }

    func testUsingCreditsOnceAPlanLimitIsReached() {
        let enabled = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 1250, utilization: 25, currency: "GBP")
        func snapshot(week: Double, credits: UsageCredits?) -> UsageSnapshot {
            UsageSnapshot(fiveHour: UsageWindow(usedPercentage: 30, resetsAt: nil),
                          sevenDay: UsageWindow(usedPercentage: week, resetsAt: nil), subscriptionType: nil, updatedAt: now, credits: credits)
        }
        XCTAssertTrue(snapshot(week: 100, credits: enabled).isUsingCredits)
        XCTAssertFalse(snapshot(week: 99, credits: enabled).isUsingCredits)
        XCTAssertFalse(snapshot(week: 100, credits: nil).isUsingCredits)
        var disabled = enabled
        disabled.isEnabled = false
        XCTAssertFalse(snapshot(week: 100, credits: disabled).isUsingCredits)
        XCTAssertFalse(snapshot(week: 100, credits: disabled).isOutOfCredits)

        let spent = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 5000, utilization: 100, currency: "GBP")
        XCTAssertFalse(snapshot(week: 100, credits: spent).isUsingCredits)
        XCTAssertTrue(snapshot(week: 100, credits: spent).isOutOfCredits)
        XCTAssertFalse(snapshot(week: 50, credits: spent).isOutOfCredits, "the plan still has room")

        var reported = snapshot(week: 50, credits: enabled)
        reported.reportsUsingCredits = true
        XCTAssertTrue(reported.isUsingCredits)
    }

    func testCreditAmounts() {
        let gbp = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 1250, utilization: 25, currency: "GBP")
        XCTAssertEqual(gbp.amountLabel(locale: Locale(identifier: "en_GB")), "£12.50 of £50.00")
        XCTAssertEqual(gbp.fraction, 0.25)
        let yen = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 1200, utilization: nil, currency: "JPY")
        XCTAssertTrue(yen.amountLabel(locale: Locale(identifier: "en_US")).contains("1,200"), "JPY has no minor unit")
        XCTAssertEqual(yen.fraction, 0.24, accuracy: 0.0001)
        XCTAssertEqual(UsageCredits(isEnabled: true, monthlyLimit: nil, usedCredits: nil, utilization: 40, currency: nil).amountLabel(), "40% used")
    }

    func testStatusLineUpdatesKeepCredits() async throws {
        let dir = try makeTemporaryDirectory()
        let usageFile = dir.appendingPathComponent("usage.json")
        let runner = FakeRunner()
        runner.usageOutput = try Fixtures.string("usage-stream.jsonl")
        // `/usage` ran long ago, so the status line file (dated now) is newer.
        let model = await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: dir),
                     hookEventsURL: dir.appendingPathComponent("h.log"), usageURL: usageFile, runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh",
                     now: { Date(timeIntervalSince1970: 1_000_000_000) }, home: "/")
        }
        await model.refreshUsage()
        try await MainActor.run {
            XCTAssertEqual(model.usage?.credits?.usedCredits, 1250)
            XCTAssertFalse(model.usage?.isUsingCredits ?? true)

            try #"{"rate_limits":{"seven_day":{"used_percentage":100,"resets_at":1790571600}}}"#.write(to: usageFile, atomically: true, encoding: .utf8)
            model.pollUsage()
            XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 100)
            XCTAssertEqual(model.usage?.credits?.usedCredits, 1250, "the status line has no credits")
            XCTAssertTrue(model.usage?.isUsingCredits ?? false)

            let logged = model.log.entries.compactMap(\.detail).joined()
            XCTAssertTrue(logged.contains("Current week (all models): 42% used"))
            XCTAssertFalse(logged.contains("used_credits"), "credit spend stays out of the Activity Log")
        }
    }
}
