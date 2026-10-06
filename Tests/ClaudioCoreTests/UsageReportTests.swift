import XCTest
@testable import ClaudioCore

/// Usage: ranges, and the figures the Usage views add up.
final class UsageReportTests: XCTestCase {
    private static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private static let now = date("2026-10-05T12:00:00Z")
    private let utc = UsageDates.calendar(TimeZone(identifier: "UTC")!)

    // MARK: - Ranges

    func testPresetRanges() {
        let week = UsageRange.week.period(now: Self.now, earliest: nil, calendar: utc)
        XCTAssertEqual(week.label, "Last 7 days")
        XCTAssertEqual(week.bars.count, 7)
        XCTAssertEqual(week.bars.first, Self.date("2026-09-29T00:00:00Z"))
        XCTAssertEqual(week.end, Self.date("2026-10-06T00:00:00Z"))
        XCTAssertEqual(week.label(ofBar: 0, calendar: utc), "29 Sep")

        let day = UsageRange.day.period(now: Self.now, earliest: nil, calendar: utc)
        XCTAssertEqual(day.bars.count, 24)
        XCTAssertEqual(day.label, "Last 24 hours")
        XCTAssertEqual(day.label(ofBar: 23, calendar: utc), "12:00")
        XCTAssertTrue(day.contains(Self.date("2026-10-05T12:30:00Z")))
        XCTAssertFalse(day.contains(Self.date("2026-10-04T11:59:00Z")))

        XCTAssertEqual(UsageRange.month.period(now: Self.now, earliest: nil, calendar: utc).bars.count, 30)
    }

    func testCustomAndAllTimeAreWorded() {
        let custom = UsageRange.custom(from: Self.date("2026-09-28T15:00:00Z"), to: Self.date("2026-09-22T09:00:00Z"))
            .period(now: Self.now, earliest: nil, calendar: utc)
        XCTAssertEqual(custom.label, "22 Sep – 28 Sep 2026")
        XCTAssertEqual(custom.bars.count, 7)
        XCTAssertTrue(custom.contains(Self.date("2026-09-28T23:59:00Z")))
        let acrossYears = UsageRange.custom(from: Self.date("2025-12-22T00:00:00Z"), to: Self.date("2026-01-03T00:00:00Z"))
            .period(now: Self.now, earliest: nil, calendar: utc)
        XCTAssertEqual(acrossYears.label, "22 Dec 2025 – 3 Jan 2026")

        let all = UsageRange.all.period(now: Self.now, earliest: Self.date("2026-08-04T10:00:00Z"), calendar: utc)
        XCTAssertEqual(all.label, "All time, since 4 Aug")
        XCTAssertEqual(all.bars.first, Self.date("2026-08-03T00:00:00Z"), "weeks start on Monday")
        XCTAssertEqual(UsageRange.all.period(now: Self.now, earliest: nil, calendar: utc).label, "All time")
    }

    func testDaysAreCountedInTheUsersTimeZone() {
        let london = UsageDates.calendar(TimeZone(identifier: "Europe/London")!)
        let period = UsageRange.week.period(now: Self.now, earliest: nil, calendar: london)
        // 23:00 UTC on the 4th is midnight on the 5th in London (BST).
        let lateHour = Date(timeIntervalSince1970: TimeInterval(UsageBucket.hour(of: Self.date("2026-10-04T23:10:00Z"))) * 3600)
        XCTAssertEqual(period.barIndex(of: lateHour), 6)
        XCTAssertEqual(period.label(ofBar: 6, calendar: london), "5 Oct")
    }

    func testRangesDecodeTolerantly() throws {
        var windows = ToolWindows()
        let project = UUID()
        windows.usageRanges[project] = .custom(from: Self.now, to: Self.now)
        windows.usageWindowRange = .month
        let decoded = try JSONDecoder().decode(ToolWindows.self, from: JSONEncoder().encode(windows))
        XCTAssertEqual(decoded, windows)

        let unknown = Data(#"{"left": "somethingNew", "usageWindowRange": {"fortnight": {}}, "usageRanges": 3}"#.utf8)
        let fallback = try JSONDecoder().decode(ToolWindows.self, from: unknown)
        XCTAssertEqual(fallback.left, .sessions)
        XCTAssertEqual(fallback.usageWindowRange, .week)
        XCTAssertEqual(fallback.usageRanges, [:])
    }

    // MARK: - Reports

    private struct Fixture {
        let model: AppModel
        let project: UUID
        let other: UUID
        let feature: UUID
        let opus: UUID
        let unfiled: UUID
        let removed: UUID
        let deleted: UUID
    }

    /// Haiku 4.5 input is $1 per million tokens, so these cost whole dollars.
    private static func conversation(project: UUID, session: UUID, name: String, folder: UUID?,
                                     _ hours: [(String, Double)]) -> ConversationUsage {
        var file = TranscriptProgress()
        file.buckets = hours.map {
            UsageBucket(hour: UsageBucket.hour(of: date($0.0)), model: "claude-haiku-4-5", tokens: TokenCounts(input: Int($0.1 * 1_000_000)))
        }
        file.turns = hours.count
        return ConversationUsage(projectID: project, sessionID: session, sessionName: name, folderID: folder, files: ["/\(name).jsonl": file])
    }

    @MainActor private func makeFixture() throws -> Fixture {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let other = state.workspace.addProject(path: "/code/site")
        let opus = Session(projectID: project, claudeSessionID: "c-opus", name: "Opus work", workingDirectory: "/code/app",
                           createdAt: Self.date("2026-10-01T00:00:00Z"))
        let unfiled = Session(projectID: project, claudeSessionID: "c-unfiled", name: "Loose end", workingDirectory: "/code/app")
        let gone = Session(projectID: project, claudeSessionID: "c-removed", name: "Old idea", workingDirectory: "/code/app")
        let site = Session(projectID: other, claudeSessionID: "c-site", name: "Site", workingDirectory: "/code/site")
        try state.workspace.addSession(opus)
        try state.workspace.addSession(unfiled)
        try state.workspace.addSession(gone)
        try state.workspace.addSession(site)
        let feature = try state.workspace.createFolder(in: project, named: "Feature", containing: opus.id)
        try state.workspace.moveSession(gone.id, to: .folder(feature))
        state.workspace.removeFromClaudio(gone.id, at: Self.now)
        let deleted = UUID()

        var ledger = UsageLedger()
        ledger.conversations["c-opus"] = Self.conversation(project: project, session: opus.id, name: "Opus work", folder: feature,
                                                           [("2026-10-05T09:00:00Z", 4)])
        ledger.conversations["c-unfiled"] = Self.conversation(project: project, session: unfiled.id, name: "Loose end", folder: nil,
                                                              [("2026-10-04T10:00:00Z", 2)])
        ledger.conversations["c-removed"] = Self.conversation(project: project, session: gone.id, name: "Old idea", folder: feature,
                                                              [("2026-10-03T10:00:00Z", 1)])
        ledger.conversations["c-deleted"] = Self.conversation(project: project, session: deleted, name: "Deleted one", folder: feature,
                                                              [("2026-09-01T10:00:00Z", 3)])
        ledger.conversations["c-site"] = Self.conversation(project: other, session: site.id, name: "Site", folder: nil,
                                                           [("2026-10-05T08:00:00Z", 10)])

        let assistant = MemoryAssistantStore()
        assistant.audit[project] = [
            AuditEntry(at: Self.date("2026-10-05T11:00:00Z"), actor: .assistant, action: .jobRan,
                       job: AuditEntry.Job(name: FollowUpJob.job, model: "Sonnet", subject: opus.id.uuidString, succeeded: true, costUSD: 0.5),
                       cause: "assistant"),
            AuditEntry(at: Self.date("2026-10-05T11:30:00Z"), actor: .assistant, action: .jobRan,
                       job: AuditEntry.Job(name: PromoteCheck.job, model: "Haiku", subject: UUID().uuidString, succeeded: true, costUSD: 0.25),
                       cause: "assistant"),
            // Unpriced calls (a failure before any reply) aren't counted.
            AuditEntry(at: Self.date("2026-10-05T11:40:00Z"), actor: .assistant, action: .jobRan,
                       job: AuditEntry.Job(name: PromoteCheck.job, model: "Haiku", subject: "x", succeeded: false), cause: "assistant"),
        ]
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: FakeRunner(),
                             assistantStore: assistant, usageStore: MemoryUsageStore(ledger),
                             locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", now: { Self.now }, home: "/")
        model.timeZone = TimeZone(identifier: "UTC")!
        return Fixture(model: model, project: project, other: other, feature: feature, opus: opus.id, unfiled: unfiled.id,
                       removed: gone.id, deleted: deleted)
    }

    func testAProjectsWeekByFolderWithTheAssistantOnTop() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let report = f.model.usageReport(.project(f.project), range: .week)
            XCTAssertEqual(report.title, "APP")
            XCTAssertEqual(report.cost, 7.75, accuracy: 0.0001)
            XCTAssertEqual(report.sessionsCost, 7, accuracy: 0.0001)
            XCTAssertEqual(report.assistantCost, 0.75, accuracy: 0.0001)
            XCTAssertEqual(report.tokens, 7_000_000)
            XCTAssertEqual(report.shareOfAll ?? 0, 7.75 / 17.75, accuracy: 0.0001)
            XCTAssertEqual(report.rows.map(\.name), ["Feature", "Unfiled"], "a removed session still counts in its folder")
            XCTAssertEqual(report.rows.map(\.cost), [5, 2])
            XCTAssertEqual(report.rows.map(\.color), [.series(0, shade: 0), .series(1, shade: 0)])
            XCTAssertEqual(report.rows[0].kind, .folder(.folder(f.feature)))

            let today = try XCTUnwrap(report.bars.last)
            XCTAssertEqual(today.label, "5 Oct")
            XCTAssertEqual(today.segments.map(\.name), ["Feature", "Assistant"])
            XCTAssertEqual(today.segments.last?.color, .assistant)
            XCTAssertEqual(today.cost, 4.75, accuracy: 0.0001)
            XCTAssertEqual(report.byModel.map(\.family), [.haiku, .sonnet])
            XCTAssertEqual(report.fallbackFamilies, [])
        }
    }

    func testAFolderListsItsSessionsRemovedOnesMutedAndOnlyItsFollowUps() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            let week = f.model.usageReport(.group(.folder(f.feature)), range: .week)
            XCTAssertEqual(week.title, "FEATURE")
            XCTAssertEqual(week.rows.map(\.name), ["Opus work", "Old idea"])
            XCTAssertEqual(week.rows.map(\.kind), [.session(f.opus), .removed])
            XCTAssertEqual(week.rows.map(\.color), [.series(0, shade: 0), .series(0, shade: 1)])
            XCTAssertEqual(week.assistantCost, 0.5, accuracy: 0.0001, "only the follow-ups on its sessions")
            XCTAssertEqual(week.cost, 5.5, accuracy: 0.0001)

            let all = f.model.usageReport(.group(.folder(f.feature)), range: .all)
            XCTAssertEqual(all.rows.map(\.name), ["Opus work", "Deleted one", "Old idea"])
            XCTAssertEqual(all.rows[1].kind, .removed)
            XCTAssertEqual(all.period.label, "All time, since 1 Sep")

            XCTAssertTrue(f.model.usageReport(.group(.folder(f.feature)), range: .day).rows.count == 1)
            let empty = f.model.usageReport(.group(.unfiled(projectID: f.project)), range: .custom(from: Self.now, to: Self.now))
            XCTAssertTrue(empty.isEmpty)
        }
    }

    func testEveryProjectAndTheAssistantsOwnFigures() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.setAssistantMode(.off, projectID: f.other)
            let all = f.model.usageReport(.all, range: .week)
            XCTAssertNil(all.shareOfAll)
            XCTAssertEqual(all.rows.map(\.name), ["site", "app"])
            XCTAssertEqual(all.cost, 17.75, accuracy: 0.0001)

            let rows = f.model.projectUsageRows(f.model.usageReport(.all, range: .week))
            XCTAssertEqual(rows.map(\.name), ["site", "app"])
            XCTAssertNil(rows[0].assistantCost, "Off: the assistant isn't on there and spent nothing")
            XCTAssertEqual(rows[1].assistantCost ?? 0, 0.75, accuracy: 0.0001)
            XCTAssertEqual(rows[1].cost, 7.75, accuracy: 0.0001)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)

            let assistant = f.model.assistantUsage(range: .week)
            XCTAssertEqual(assistant.calls, 2)
            XCTAssertEqual(assistant.cost, 0.75, accuracy: 0.0001)
            XCTAssertEqual(assistant.shareOfAll, 0.75 / 17.75, accuracy: 0.0001)
            XCTAssertEqual(assistant.jobs.map(\.name), [FollowUpJob.job, PromoteCheck.job])
            XCTAssertEqual(assistant.projects.map(\.name), ["app"])

            XCTAssertEqual(f.model.todayUsageCost, 14.75, accuracy: 0.0001)
        }
    }

    func testASessionsAllTimeUsageAndItsPartOfTheWeek() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            var usage = try XCTUnwrap(f.model.sessionUsage(f.opus))
            XCTAssertEqual(usage.cost, 4, accuracy: 0.0001)
            XCTAssertEqual(usage.tokens.input, 4_000_000)
            XCTAssertEqual(usage.turns, 1)
            XCTAssertEqual(usage.mainModel, "Haiku 4.5")
            XCTAssertEqual(usage.followUpCost ?? 0, 0.5, accuracy: 0.0001)
            XCTAssertNil(usage.weekShare, "no weekly reading yet")

            f.model.applyTestUsage(UsageSnapshot(fiveHour: nil, sevenDay: UsageWindow(usedPercentage: 31, resetsAt: nil), subscriptionType: nil,
                                                 updatedAt: Self.now))
            usage = try XCTUnwrap(f.model.sessionUsage(f.opus))
            XCTAssertEqual(usage.weekShare ?? 0, 4 / 17.75 * 0.31, accuracy: 0.0001)
            XCTAssertEqual(usage.weekUsed, 31)
            XCTAssertNil(f.model.sessionUsage(UUID()))

            f.model.applyTestUsage(UsageSnapshot(fiveHour: nil, sevenDay: UsageWindow(usedPercentage: 0, resetsAt: nil), subscriptionType: nil,
                                                 updatedAt: Self.now))
            XCTAssertNil(f.model.sessionUsage(f.opus)?.weekShare)
        }
    }

    func testANewAssistantCallCountsStraightAway() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.recordAssistantCost(AuditEntry.Job(name: FollowUpJob.job, model: "Sonnet", subject: f.unfiled.uuidString,
                                                       succeeded: true, costUSD: 1), at: Self.now, projectID: f.project)
            XCTAssertEqual(f.model.sessionUsage(f.unfiled)?.followUpCost ?? 0, 1, accuracy: 0.0001)
            XCTAssertEqual(f.model.usageReport(.project(f.project), range: .day).assistantCost, 1.75, accuracy: 0.0001)
        }
    }

    func testTheToolFollowsTheProjectAndForgetsAFolderElsewhere() throws {
        try MainActor.assumeIsolated {
            let f = try makeFixture()
            f.model.select(f.opus)
            XCTAssertEqual(f.model.usageProjectID, f.project)
            f.model.showUsage(of: .folder(f.feature))
            XCTAssertEqual(f.model.currentUsageFolder, .folder(f.feature))
            XCTAssertEqual(f.model.usageRange(forProject: f.project), .week)
            f.model.setUsageRange(.all, forProject: f.project)
            XCTAssertEqual(f.model.usageRange(forProject: f.project), .all)
            XCTAssertEqual(f.model.usageRange(forProject: f.other), .week)

            let site = try XCTUnwrap(f.model.workspace.sessions.first { $0.projectID == f.other })
            f.model.select(site.id)
            XCTAssertNil(f.model.currentUsageFolder)

            f.model.showSessionUsage(f.opus)
            XCTAssertEqual(f.model.selectedSessionID, f.opus)
            XCTAssertEqual(f.model.visibleSessionTool, .usage)
        }
    }

    func testDeletingReadsTheRestOfTheTranscriptFirst() async throws {
        let home = try makeTemporaryDirectory()
        let discovery = SessionDiscovery(claudeHome: home)
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let session = Session(projectID: project, claudeSessionID: "c1", name: "Doomed", workingDirectory: "/code/app")
        try state.workspace.addSession(session)
        let directory = discovery.projectDirectory(for: "/code/app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contentsOf: Fixtures.url("transcript-usage.jsonl")).write(to: directory.appendingPathComponent("c1.jsonl"))
        let store = MemoryStore()
        store.state = state
        let usageStore = MemoryUsageStore()
        let model = await MainActor.run {
            AppModel(store: store, discovery: discovery, hookEventsURL: home.appendingPathComponent("h.log"), runner: FakeRunner(),
                     usageStore: usageStore, locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil },
                     shell: "/bin/sh", now: { Self.now }, home: "/")
        }
        await MainActor.run { model.deleteSession(session.id, .everywhere) }
        await model.lastTask?.value
        await MainActor.run {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("c1.jsonl").path))
            XCTAssertEqual(model.usageEntries.reduce(0) { $0 + $1.cost }, 3.307508, accuracy: 0.000001)
            let report = model.usageReport(.project(project), range: .all)
            XCTAssertEqual(report.rows.map(\.name), ["Unfiled"])
            let folder = model.usageReport(.group(.unfiled(projectID: project)), range: .all)
            XCTAssertEqual(folder.rows.map(\.name), ["Doomed"])
            XCTAssertEqual(folder.rows.map(\.kind), [.removed])
            XCTAssertEqual(folder.fallbackFamilies, [.sonnet])
        }
    }

    func testScanningReadsEverySessionsTranscripts() async throws {
        let home = try makeTemporaryDirectory()
        let discovery = SessionDiscovery(claudeHome: home)
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        var session = Session(projectID: project, claudeSessionID: "c-old", name: "Cleared", workingDirectory: "/code/app")
        session.adoptConversation("c-new")
        try state.workspace.addSession(session)
        let directory = discovery.projectDirectory(for: "/code/app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: Fixtures.url("transcript-usage.jsonl"))
        try data.write(to: directory.appendingPathComponent("c-old.jsonl"))
        try Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"msg_", with: "\"new_")
            .replacingOccurrences(of: "\"u-", with: "\"n-").utf8).write(to: directory.appendingPathComponent("c-new.jsonl"))
        let store = MemoryStore()
        store.state = state
        let usageStore = MemoryUsageStore()
        let model = await MainActor.run {
            AppModel(store: store, discovery: discovery, hookEventsURL: home.appendingPathComponent("h.log"), runner: FakeRunner(),
                     usageStore: usageStore, locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh",
                     now: { Self.now }, home: "/")
        }
        await model.refreshUsageLedger()
        await MainActor.run {
            XCTAssertEqual(model.sessionUsage(session.id)?.cost ?? 0, 2 * 3.307508, accuracy: 0.000001, "a /clear'd conversation is still its")
            XCTAssertEqual(model.sessionUsage(session.id)?.turns, 4)
            XCTAssertNil(model.usageScan.reading)
            XCTAssertEqual(model.usageScan.unreadable, [:])
        }
        // Saved off the main actor.
        for _ in 0..<50 where usageStore.ledger == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(usageStore.ledger?.conversations.count, 2)
    }
}
