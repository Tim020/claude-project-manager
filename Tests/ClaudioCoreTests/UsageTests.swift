import XCTest
@testable import ClaudioCore

final class UsageTests: XCTestCase {
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

    func testSettingsJSONIncludesStatusLineWhenCapturing() throws {
        let capture = StatusLineCapture(statusDirectory: "/tmp/status", userStatusLine: UserStatusLine(command: "x", padding: 2))
        let json = HookSettings.json(appSessionID: UUID(), eventsPath: "/tmp/h.log", statusLine: capture)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["statusLine"]?["type"], .string("command"))
        XCTAssertEqual(value["statusLine"]?["padding"], .number(2))
        XCTAssertNil(value["statusLine"]?["refreshInterval"], "nothing to refresh while idle: usage comes from /usage")
        XCTAssertNotNil(value["hooks"])
        XCTAssertNil(try JSONDecoder().decode(JSONValue.self, from: Data(HookSettings.json(appSessionID: UUID(), eventsPath: "/x").utf8))["statusLine"])
    }

    func testAWindowPastItsResetShowsNothingUsed() {
        let resets = Date(timeIntervalSince1970: 1_790_481_000)
        let window = UsageWindow(usedPercentage: 100, resetsAt: resets)
        XCTAssertEqual(window.current(at: resets.addingTimeInterval(-60)), window)
        XCTAssertEqual(window.current(at: resets.addingTimeInterval(60)).usedPercentage, 0)
        XCTAssertEqual(window.current(at: resets.addingTimeInterval(60)).resetLabel(now: resets), "", "not \"resets in 1m\" forever")

        let credits = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 1000, utilization: 20, currency: "GBP")
        let full = UsageSnapshot(fiveHour: window, sevenDay: nil, subscriptionType: nil, updatedAt: resets, credits: credits)
        XCTAssertTrue(full.current(at: resets.addingTimeInterval(-60)).isUsingCredits)
        XCTAssertFalse(full.current(at: resets.addingTimeInterval(60)).isUsingCredits, "the badge follows the reset")
    }

    func testOldReadingsAreStale() {
        let snapshot = UsageSnapshot(fiveHour: nil, sevenDay: nil, subscriptionType: nil, updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(snapshot.isStale(at: Date(timeIntervalSince1970: 179), refreshInterval: 60), "a missed poll or two is fine")
        XCTAssertTrue(snapshot.isStale(at: Date(timeIntervalSince1970: 181), refreshInterval: 60))
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
        XCTAssertEqual(usage.credits, UsageCredits(isEnabled: true, monthlyLimit: 8000, usedCredits: 2000, utilization: 25, currency: "GBP"))
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

        let assistant = JSONValue.object(["type": .string("assistant"), "message": .object([
            "content": .array([.object(["type": .string("text"), "text": .string("Current week (all models): 7% used")])]),
        ])])
        let fromMessage = try UsageSnapshot.parseUsageStream(String(decoding: JSONEncoder().encode(assistant), as: UTF8.self), updatedAt: now)
        XCTAssertEqual(fromMessage?.sevenDay?.usedPercentage, 7, "no result event: the message text")
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

    func testEachUsageReadingReplacesTheLast() async throws {
        let runner = FakeRunner()
        runner.usageOutput = try Fixtures.string("usage-stream.jsonl")
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        await model.checkEnvironment()
        await model.refreshUsage()
        await model.refreshUsage()
        try await MainActor.run {
            XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 42)
            XCTAssertEqual(model.usage?.credits?.usedCredits, 2000)
            XCTAssertEqual(model.usage?.subscriptionType, "pro", "the plan comes from `claude auth status`")
            let logged = model.log.entries.filter { $0.title.contains("/usage") }
            XCTAssertEqual(logged.count, 1, "an unchanged reading isn't logged again")
            XCTAssertTrue(logged.compactMap(\.detail).joined().contains("Current week (all models): 42% used"))
            XCTAssertFalse(logged.compactMap(\.detail).joined().contains("used_credits"), "credit spend stays out of the Activity Log")

            // A lower figure after a reset replaces the old one: there's nothing to merge.
            runner.usageOutput = try Fixtures.string("usage-stream.jsonl").replacingOccurrences(of: #""percent":42"#, with: #""percent":1"#)
        }
        await model.refreshUsage()
        await MainActor.run { XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 1) }

        // A read that fails keeps the last figures.
        runner.usageOutput = ""
        await model.refreshUsage()
        await MainActor.run { XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 1) }
    }

    func testOverageTextNextToAReport() throws {
        let stream = try Fixtures.string("usage-stream.jsonl")
            .replacingOccurrences(of: "You are currently using your subscription", with: "You are currently using your overages")
        let usage = try XCTUnwrap(UsageSnapshot.parseUsageStream(stream, updatedAt: now))
        XCTAssertEqual(usage.fiveHour?.usedPercentage, 5, "the report's windows are still used")
        XCTAssertTrue(usage.reportsUsingCredits)
        XCTAssertTrue(usage.isUsingCredits, "on credits with no window at 100%")
    }

    func testAReportWithoutUsableWindowsFallsBackToTheText() throws {
        let fixture = try Fixtures.string("usage-stream.jsonl")
        // Kinds this version doesn't know (another account type, or renamed).
        let renamed = fixture.replacingOccurrences(of: #""kind":"session""#, with: #""kind":"session_v2""#)
            .replacingOccurrences(of: #""kind":"weekly_all""#, with: #""kind":"weekly_v2""#)
        let usage = try XCTUnwrap(UsageSnapshot.parseUsageStream(renamed, updatedAt: now))
        XCTAssertEqual(usage.fiveHour?.usedPercentage, 5)
        XCTAssertEqual(usage.sevenDay?.usedPercentage, 42)
        XCTAssertNil(usage.fiveHour?.resetsAt, "from the text")
        XCTAssertEqual(usage.credits?.usedCredits, 2000, "credits still come from the report")

        // `"rate_limits": null`
        let noLimits = fixture.replacingOccurrences(of: #""rate_limits":{"limits":"#, with: #""rate_limits":null,"unused":{"limits":"#)
        let fromText = try XCTUnwrap(UsageSnapshot.parseUsageStream(noLimits, updatedAt: now))
        XCTAssertEqual(fromText.sevenDay?.usedPercentage, 42)
        XCTAssertNil(fromText.credits)
    }

    func testPlanNameWhenUsageAnswersBeforeSignIn() async throws {
        let runner = FakeRunner()
        runner.usageOutput = try Fixtures.string("usage-stream.jsonl")
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        await model.refreshUsage()
        await MainActor.run { XCTAssertNil(model.usage?.subscriptionType, "sign-in not checked yet") }
        await model.checkEnvironment()
        await MainActor.run { XCTAssertEqual(model.usage?.subscriptionType, "pro", "applied once sign-in is known") }
        await model.refreshUsage()
        await MainActor.run { XCTAssertEqual(model.usage?.subscriptionType, "pro") }
    }

    func testUnreadableUsageIsLoggedOnce() async throws {
        let runner = FakeRunner()
        runner.usageOutput = "Error: something went wrong\n"
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        await model.refreshUsage()
        await model.refreshUsage()
        try await MainActor.run {
            XCTAssertNil(model.usage)
            XCTAssertEqual(model.log.entries.filter { $0.title == "Couldn't read plan usage" }.count, 1)
            let command = try XCTUnwrap(model.log.entries.first { $0.title.contains("/usage") })
            XCTAssertTrue(command.detail?.contains("Error: something went wrong") ?? false, "output that isn't a report is logged as it is")
        }
        runner.usageOutput = try Fixtures.string("usage-stream.jsonl")
        await model.refreshUsage()
        runner.usageOutput = "Error: something went wrong\n"
        await model.refreshUsage()
        await MainActor.run {
            XCTAssertEqual(model.log.entries.filter { $0.title == "Couldn't read plan usage" }.count, 2, "logged again after a good reading")
            XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 42, "the last reading is kept")
        }
    }
}
