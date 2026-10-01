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

        var reported = full
        reported.fiveHour?.usedPercentage = 50
        reported.reportsUsingCredits = true
        XCTAssertTrue(reported.current(at: resets.addingTimeInterval(-60)).isUsingCredits)
        XCTAssertFalse(reported.current(at: resets.addingTimeInterval(60)).isUsingCredits, "the overage header is from before the reset")
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

    func testCreditsInUseOnlyWhileDrawingOnThem() {
        let enabled = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 1250, utilization: 25, currency: "GBP")
        let resets = now.addingTimeInterval(3600)
        let full = UsageSnapshot(fiveHour: UsageWindow(usedPercentage: 100, resetsAt: resets), sevenDay: UsageWindow(usedPercentage: 40, resetsAt: nil),
                                 subscriptionType: nil, updatedAt: now, credits: enabled)
        XCTAssertEqual(full.creditsInUse, enabled)
        XCTAssertEqual(full.creditsInUse?.amountLabel(locale: Locale(identifier: "en_GB")), "£12.50 of £50.00")
        XCTAssertNil(full.current(at: resets.addingTimeInterval(60)).creditsInUse, "back on the plan after the reset")

        var spent = full
        spent.credits = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 5000, utilization: 100, currency: "GBP")
        XCTAssertNil(spent.creditsInUse, "out of credits: the plan windows show")
        var roomLeft = full
        roomLeft.fiveHour = UsageWindow(usedPercentage: 80, resetsAt: nil)
        XCTAssertNil(roomLeft.creditsInUse)
    }

    func testBlockedLabelOnceOutOfCredits() {
        let spent = UsageCredits(isEnabled: false, monthlyLimit: 5000, usedCredits: 5000, utilization: 100, currency: "GBP")
        let session = now.addingTimeInterval(2 * 3600 + 14 * 60)
        let week = now.addingTimeInterval(3 * 86400 + 4 * 3600)
        var usage = UsageSnapshot(fiveHour: UsageWindow(usedPercentage: 100, resetsAt: session), sevenDay: UsageWindow(usedPercentage: 60, resetsAt: week),
                                  subscriptionType: nil, updatedAt: now, credits: spent)
        XCTAssertEqual(usage.blockedLabel(now: now), "back in 2h 14m")
        XCTAssertNil(usage.current(at: session.addingTimeInterval(60)).blockedLabel(now: session.addingTimeInterval(60)), "the session reset unblocks it")

        usage.sevenDay?.usedPercentage = 100
        XCTAssertEqual(usage.blockedLabel(now: now), "back in 3d 4h", "both full: the later reset")

        usage.sevenDay = UsageWindow(usedPercentage: 100, resetsAt: nil, resetText: "Oct 6")
        XCTAssertNil(usage.blockedLabel(now: now), "a window with no timestamp can't be compared")
        usage.fiveHour = nil
        XCTAssertEqual(usage.blockedLabel(now: now), "back Oct 6")

        var credits = usage
        credits.credits = UsageCredits(isEnabled: true, monthlyLimit: 5000, usedCredits: 1250, utilization: 25, currency: "GBP")
        XCTAssertNil(credits.blockedLabel(now: now), "still on credits")
    }

    func testSpentCreditsStayShownWhenTurnedOff() throws {
        // Hitting the monthly spend limit turns `is_enabled` off (2.1.283:
        // `"is_enabled":false,…,"used_credits":5031,"utilization":100` against
        // a limit of 5000). The spend and the out-of-credits state still show.
        let fixture = try Fixtures.string("usage-stream.jsonl")
            .replacingOccurrences(of: #""percent":42"#, with: #""percent":100"#)
        let spent = fixture.replacingOccurrences(of: #""is_enabled":true,"monthly_limit":8000,"used_credits":2000,"utilization":25.0"#,
                                                 with: #""is_enabled":false,"monthly_limit":8000,"used_credits":8050,"utilization":100"#)
        XCTAssertNotEqual(spent, fixture)
        let usage = try XCTUnwrap(UsageSnapshot.parseUsageStream(spent, updatedAt: now))
        let credits = try XCTUnwrap(usage.credits)
        XCTAssertFalse(credits.isEnabled)
        XCTAssertTrue(credits.isShown)
        XCTAssertTrue(usage.isOutOfCredits)
        XCTAssertFalse(usage.isUsingCredits)

        // No `is_enabled` at all: the spend is still read.
        let unflagged = spent.replacingOccurrences(of: #""is_enabled":false,"#, with: "")
        XCTAssertTrue(try XCTUnwrap(UsageSnapshot.parseUsageStream(unflagged, updatedAt: now)).isOutOfCredits)

        // Never turned on: nothing spent, nothing shown.
        let off = fixture.replacingOccurrences(of: #""is_enabled":true,"monthly_limit":8000,"used_credits":2000,"utilization":25.0"#,
                                               with: #""is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null"#)
        let never = try XCTUnwrap(UsageSnapshot.parseUsageStream(off, updatedAt: now))
        XCTAssertEqual(never.credits?.isShown, false)
        XCTAssertFalse(never.isOutOfCredits)

        // `"extra_usage": null`
        let noCredits = fixture.replacingOccurrences(of: #""extra_usage":{"#, with: #""extra_usage":null,"unused":{"#)
        XCTAssertNil(try XCTUnwrap(UsageSnapshot.parseUsageStream(noCredits, updatedAt: now)).credits)
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

    func testOverlappingRefreshesRunOneCommand() async throws {
        let runner = FakeRunner()
        runner.usageOutput = try Fixtures.string("usage-stream.jsonl")
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        // Launch: coming to the front and the poll's first reading at once.
        async let poll: Void = model.refreshUsage()
        async let activation: Void = model.refreshUsageIfDue()
        _ = await (poll, activation)
        XCTAssertEqual(runner.commands.filter { $0.contains("/usage") }.count, 1)
        await model.refreshUsage()
        XCTAssertEqual(runner.commands.filter { $0.contains("/usage") }.count, 2, "the guard is released afterwards")
    }

    func testRefreshesOnActivationOnlyWhenDue() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_790_380_000) }
        let clock = Clock()
        let runner = FakeRunner()
        let fixture = try Fixtures.string("usage-stream.jsonl")
        runner.usageOutput = fixture
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", now: { clock.now }, home: "/")
        }
        await model.refreshUsageIfDue()
        await MainActor.run { XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 42, "no reading yet") }

        runner.usageOutput = fixture.replacingOccurrences(of: #""percent":42"#, with: #""percent":43"#)
        clock.now += 30
        await model.refreshUsageIfDue()
        await MainActor.run { XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 42, "read 30 s ago") }
        clock.now += 31
        await model.refreshUsageIfDue()
        await MainActor.run { XCTAssertEqual(model.usage?.sevenDay?.usedPercentage, 43) }
    }
}
