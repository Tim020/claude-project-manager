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
                                 locateClaude: { _ in nil }, shell: "/bin/sh", now: { Date(timeIntervalSince1970: 1_790_340_000) }, home: "/")
            XCTAssertNil(model.usage)
            try statusLineInput.write(to: dir.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)
            model.pollUsage()
            XCTAssertEqual(model.usage?.fiveHour?.usedPercentage, 56.2)
        }
    }

    // Readings recorded from several sessions' status lines at once: the idle
    // ones kept reporting the figure from their last request.
    private func reading(fiveHour: (Double, TimeInterval)?, week: (Double, TimeInterval)? = nil) -> UsageSnapshot {
        func window(_ value: (Double, TimeInterval)?) -> UsageWindow? {
            value.map { UsageWindow(usedPercentage: $0.0, resetsAt: Date(timeIntervalSince1970: $0.1)) }
        }
        return UsageSnapshot(fiveHour: window(fiveHour), sevenDay: window(week), subscriptionType: nil, updatedAt: Date())
    }

    func testAStaleLowerReadingDoesNotLowerTheWindow() {
        let now = Date(timeIntervalSince1970: 1_790_460_000)
        let active = reading(fiveHour: (73, 1_790_463_000), week: (38, 1_790_571_600))
        let idle = reading(fiveHour: (40, 1_790_463_000), week: (33, 1_790_571_600))
        let merged = active.merged(with: idle, now: now)
        XCTAssertEqual(merged.fiveHour?.usedPercentage, 73)
        XCTAssertEqual(merged.sevenDay?.usedPercentage, 38)
        XCTAssertEqual(merged.merged(with: reading(fiveHour: (75, 1_790_463_000)), now: now).fiveHour?.usedPercentage, 75)
    }

    func testAReadingFromAWindowThatHasResetIsDropped() {
        let now = Date(timeIntervalSince1970: 1_790_463_100)
        let fresh = reading(fiveHour: (1, 1_790_481_000))
        let stale = reading(fiveHour: (73, 1_790_463_000))
        XCTAssertEqual(fresh.merged(with: stale, now: now).fiveHour?.usedPercentage, 1)
        XCTAssertEqual(stale.merged(with: fresh, now: now).fiveHour?.usedPercentage, 1)
        // Before the reset, a later window still wins over an earlier one.
        XCTAssertEqual(fresh.merged(with: stale, now: Date(timeIntervalSince1970: 1_790_460_000)).fiveHour?.usedPercentage, 1)
    }

    func testAReadingWithoutAWindowKeepsTheCurrentOne() {
        let now = Date(timeIntervalSince1970: 1_790_460_000)
        let current = reading(fiveHour: (73, 1_790_463_000), week: (38, 1_790_571_600))
        let merged = current.merged(with: reading(fiveHour: nil, week: (41, 1_790_571_600)), now: now)
        XCTAssertEqual(merged.fiveHour?.usedPercentage, 73)
        XCTAssertEqual(merged.sevenDay?.usedPercentage, 41)
    }

    func testUsageCommandReadingKeepsTheKnownResetTime() {
        let now = Date(timeIntervalSince1970: 1_790_460_000)
        let command = UsageSnapshot(fiveHour: UsageWindow(usedPercentage: 74, resetsAt: nil, resetText: "11:50pm"),
                                    sevenDay: nil, subscriptionType: "max", updatedAt: Date())
        let merged = reading(fiveHour: (73, 1_790_463_000)).merged(with: command, now: now)
        XCTAssertEqual(merged.fiveHour?.usedPercentage, 74)
        XCTAssertEqual(merged.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_790_463_000))
        XCTAssertEqual(merged.subscriptionType, "max")
        // A timed reading replaces an untimed one, since they can't be compared.
        XCTAssertEqual(command.merged(with: reading(fiveHour: (1, 1_790_481_000)), now: now).fiveHour?.usedPercentage, 1)
        // `/usage` is always current, so a lower one after a reset replaces the old figure.
        var afterReset = command
        afterReset.fiveHour = UsageWindow(usedPercentage: 2, resetsAt: nil, resetText: "4:50am")
        XCTAssertEqual(command.merged(with: afterReset, now: now).fiveHour?.usedPercentage, 2)
        // …and it doesn't bring back a status line's reset time that has passed.
        let expired = reading(fiveHour: (73, 1_790_459_000)).merged(with: afterReset, now: now).fiveHour
        XCTAssertEqual(expired?.usedPercentage, 2)
        XCTAssertNil(expired?.resetsAt)
    }

    func testAWindowThatHasResetShowsNothingUsed() {
        let window = UsageWindow(usedPercentage: 73, resetsAt: Date(timeIntervalSince1970: 1_790_463_000))
        XCTAssertEqual(window.current(at: Date(timeIntervalSince1970: 1_790_462_000)), window)
        let reset = window.current(at: Date(timeIntervalSince1970: 1_790_463_100))
        XCTAssertEqual(reset.usedPercentage, 0)
        XCTAssertEqual(reset.resetLabel(now: Date()), "")
    }

    func testModelTakesTheHighestReadingAcrossSessions() throws {
        try MainActor.assumeIsolated {
            let dir = try makeTemporaryDirectory()
            let status = dir.appendingPathComponent("status")
            try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true)
            let model = AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: dir),
                                 hookEventsURL: dir.appendingPathComponent("h.log"), usageURL: dir.appendingPathComponent("usage.json"),
                                 statusDirectory: status, locateClaude: { _ in nil }, shell: "/bin/sh",
                                 now: { Date(timeIntervalSince1970: 1_790_460_000) }, home: "/")
            func input(_ used: Int) -> String {
                #"{"rate_limits":{"five_hour":{"used_percentage":\#(used),"resets_at":1790463000}}}"#
            }
            // The active session wrote the shared file, then an idle one overwrote it.
            try input(73).write(to: status.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
            try input(40).write(to: status.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
            try input(40).write(to: dir.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)
            model.pollUsage()
            XCTAssertEqual(model.usage?.fiveHour?.usedPercentage, 73)
            // Another stale write to the shared file doesn't bring it back down.
            try input(45).write(to: dir.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)
            model.pollUsage()
            XCTAssertEqual(model.usage?.fiveHour?.usedPercentage, 73)
        }
    }
}
