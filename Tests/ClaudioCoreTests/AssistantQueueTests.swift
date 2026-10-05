import XCTest
@testable import ClaudioCore

/// Answers assistant calls with a Promote reply, and everything else as
/// `FakeRunner` does.
private final class QueueRunner: CommandRunning, @unchecked Sendable {
    let base = FakeRunner()
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        guard command.claudeArguments.contains("--json-schema") else { return await base.run(command) }
        lock.withLock { _calls.append(command.claudeArguments) }
        return CommandResult(exitCode: 0, output: #"{"type":"result","subtype":"success","is_error":false,"duration_ms":5000,"total_cost_usd":0.004,"structured_output":{"kind":"idea","promote":true,"title":"A title","duplicateOf":null,"reason":"Reads like an idea."}}"#,
                             errorOutput: "")
    }
}

/// Step 4b: held-back work, Assistant Settings, the status line and the
/// Activity Log.
final class AssistantQueueTests: XCTestCase {
    static let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!

    private struct Fixture {
        let model: AppModel
        let runner: QueueRunner
        let assistant: MemoryAssistantStore
        let project: UUID
    }

    /// Signed in with an API key (no usage reading), so the daily limit is
    /// the gate that holds work back.
    private func makeFixture(assistant: MemoryAssistantStore = MemoryAssistantStore()) async throws -> Fixture {
        let runner = QueueRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "api_key"}"#
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let store = MemoryStore()
        store.state = state
        let model = await MainActor.run {
            AppModel(store: store, discovery: SessionDiscovery(claudeHome: try! makeTemporaryDirectory()),
                     hookEventsURL: try! makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     assistantStore: assistant, locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil },
                     shell: "/bin/sh", now: { AssistantQueueTests.now }, home: "/")
        }
        await model.checkEnvironment(force: true)
        return Fixture(model: model, runner: runner, assistant: assistant, project: project)
    }

    @MainActor private func atDailyLimit(_ f: Fixture) {
        f.model.dailyJobs = DailyJobCount(day: DailyJobCount.day(of: AssistantQueueTests.now), count: f.model.settings.assistant.dailyJobLimit)
    }

    @MainActor private func capture(_ f: Fixture, _ text: String) throws -> ProjectNote {
        let note = try XCTUnwrap(f.model.addNote(text, author: .user, projectID: f.project, sessionID: nil))
        f.model.checkCapturedNote(note, projectID: f.project)
        return note
    }

    // MARK: Held-back work

    func testACheckHeldBackWaitsAndRunsWhenTheGateOpens() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            atDailyLimit(f)
            _ = try capture(f, "Shell panel height resets on relaunch")
            XCTAssertEqual(f.model.heldJobs(inProject: f.project).map(\.job), ["Promote check"])
            XCTAssertEqual(f.model.heldJobs.first?.subject, "Shell panel height resets on relaunch")
            XCTAssertEqual(f.model.assistantStatusLine(forProject: f.project), .paused(reason: "Daily limit of 20 reached", waiting: 1))
            XCTAssertEqual(f.model.assistantLog(forProject: f.project).first?.result, .waiting(reason: "Daily limit of 20 reached"))

            var settings = f.model.settings
            settings.assistant.dailyJobLimit = 25        // a settings change releases it
            f.model.updateSettings(settings)
            XCTAssertTrue(f.model.heldJobs.isEmpty)
        }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "it ran once the gate opened")
        let count = await MainActor.run { f.model.backgroundJobsToday }
        XCTAssertEqual(count, 21, "counted when it ran, not when it was held")
        await MainActor.run {
            f.model.releaseHeldJobs()
            var settings = f.model.settings
            settings.assistant.dailyJobLimit = 30
            f.model.updateSettings(settings)
        }
        await f.model.checkFollowUps()
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "later releases, ticks and settings changes don't run it again")
    }

    func testTheNextDayReleasesWorkTheLimitHeld() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            atDailyLimit(f)
            _ = try capture(f, "A note")
            f.model.dailyJobs = DailyJobCount(day: "2026-09-30", count: 20)        // midnight has passed
        }
        await f.model.checkFollowUps()        // the 15 s tick releases held work
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1)
        let today = await MainActor.run { f.model.backgroundJobsToday }
        XCTAssertEqual(today, 1, "counted against the new day")
    }

    func testANewerJobWithTheSameKeyReplacesAHeldOne() async throws {
        let f = try await makeFixture()
        let ran = await MainActor.run { Ran() }
        await MainActor.run {
            atDailyLimit(f)
            let key = HeldJobKey.noteCheck(UUID())
            f.model.runOrHoldBackground(key: key, projectID: f.project, job: "t", subject: "first", model: "Haiku") { ran.names.append("first"); return false }
            f.model.runOrHoldBackground(key: key, projectID: f.project, job: "t", subject: "second", model: "Haiku") { ran.names.append("second"); return false }
            XCTAssertEqual(f.model.heldJobs.map(\.subject), ["second"])
            f.model.dailyJobs = nil
            f.assistant.dailyJobs = nil
            f.model.releaseHeldJobs()
            XCTAssertEqual(ran.names, ["second"])
            f.model.releaseHeldJobs()
            XCTAssertEqual(ran.names, ["second"], "a second release doesn't run it again")
            XCTAssertNotNil(f.model.log.entries.last { $0.title == "Assistant: t skipped: no longer needed" }, "and it says why it ran nothing")
        }
    }

    func testOffDropsHeldWorkAndOffers() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            atDailyLimit(f)
            _ = try capture(f, "A note")
            let offer = FollowUp(sessionID: UUID(), sessionName: "s", state: .offered, createdAt: Date(), askedFor: false)
            f.model.updateNeedsYou(f.project) { $0.followUps.append(offer) }
            f.model.setAssistantMode(.off, projectID: f.project)
            XCTAssertTrue(f.model.heldJobs.isEmpty, "held work is dropped")
            XCTAssertTrue(f.model.needsYouData(inProject: f.project).followUps.isEmpty, "offers are withdrawn")
            XCTAssertEqual(f.model.assistantStatusLine(forProject: f.project), .offInProject)
        }
    }

    func testTurningTheAssistantOffEverywhereDropsHeldWork() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            atDailyLimit(f)
            _ = try capture(f, "A note")
            let offer = FollowUp(sessionID: UUID(), sessionName: "s", state: .offered, createdAt: Date(), askedFor: false)
            f.model.updateNeedsYou(f.project) { $0.followUps.append(offer) }
            var settings = f.model.settings
            settings.assistant.isEnabled = false
            f.model.updateSettings(settings)
            XCTAssertTrue(f.model.heldJobs.isEmpty)
            XCTAssertTrue(f.model.needsYouData(inProject: f.project).followUps.isEmpty, "offers are withdrawn")
            XCTAssertNotNil(f.model.log.entries.last { $0.title.hasPrefix("Assistant: dropped 1 waiting job and 1 follow-up offer") })
            XCTAssertEqual(f.model.assistantStatusLine(forProject: f.project), .offEverywhere)
            f.model.turnAssistantOn(inProject: f.project)
            XCTAssertTrue(f.model.settings.assistant.isEnabled, "Turn On turns the switch back on")
        }
    }

    func testAHeldCheckWhoseNoteWasPromotedMakesNoCall() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            atDailyLimit(f)
            let note = try capture(f, "A note")
            f.model.promoteNote(note.id, projectID: f.project)
            f.model.dailyJobs = DailyJobCount(day: "2026-09-30", count: 0)
            f.model.releaseHeldJobs()
            XCTAssertEqual(f.model.backgroundJobsToday, 0, "not counted: it didn't call Claude")
        }
        await f.model.waitForAssistantJobs()
        XCTAssertTrue(f.runner.calls.isEmpty, "the note has its item, so nothing to check")
    }

    func testCheckingItYourselfReplacesTheHeldCheck() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            atDailyLimit(f)
            let note = try capture(f, "A note")
            f.model.requestPromote(note.id, projectID: f.project)
            XCTAssertTrue(f.model.heldJobs.isEmpty)
        }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "yours runs now, whatever the limit")
    }

    func testManualHasItsOwnLineAndNothingIsHeld() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            f.model.setAssistantMode(.manual, projectID: f.project)
            atDailyLimit(f)
            _ = try capture(f, "A note")
            XCTAssertTrue(f.model.heldJobs.isEmpty, "Manual: no background work to hold")
            XCTAssertEqual(f.model.assistantStatusLine(forProject: f.project), .manual)
            f.model.setAssistantMode(.automatic, projectID: f.project)
            XCTAssertEqual(f.model.assistantStatusLine(forProject: f.project), .paused(reason: "Daily limit of 20 reached", waiting: 0))
        }
    }

    // MARK: Assistant Settings

    func testProjectSettingsChooseTheModelAndTheBudget() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            var settings = f.model.assistantSettings(forProject: f.project)
            settings.quickModel = .opus
            f.model.setAssistantSettings(settings, projectID: f.project)
            XCTAssertEqual(f.assistant.projectSettings[f.project]?.quickModel, .opus, "saved")
            let note = try XCTUnwrap(f.model.addNote("A note", author: .user, projectID: f.project, sessionID: nil))
            f.model.requestPromote(note.id, projectID: f.project)
        }
        await f.model.waitForAssistantJobs()
        let call = try XCTUnwrap(f.runner.calls.first)
        XCTAssertTrue(call.containsSequence(["--model", "opus"]))
        XCTAssertTrue(call.containsSequence(["--max-budget-usd", "0.75"]), "Haiku's $0.05 scaled for Opus")
        let row = await MainActor.run { () -> AssistantLogRow? in
            f.model.refreshAssistantLog(projectID: f.project)
            return f.model.assistantLog(forProject: f.project).first
        }
        XCTAssertEqual(row?.model, "Opus")
        XCTAssertEqual(row?.subject, "A note")
    }

    func testSettingsAreReadBackAtLaunch() async throws {
        let assistant = MemoryAssistantStore()
        let first = try await makeFixture(assistant: assistant)
        var saved = ProjectAssistantSettings()
        saved.dontSendTranscripts = true
        saved.deepModel = .haiku
        assistant.projectSettings[first.project] = saved
        let reopened = await MainActor.run { () -> ProjectAssistantSettings in
            first.model.prepareAssistantFiles()
            return first.model.assistantSettings(forProject: first.project)
        }
        XCTAssertEqual(reopened, saved)
    }

    func testDontSendTranscriptsLeavesThemOutOfTheCall() {
        var digest = SessionDigest()
        digest.prompts = ["Store it per project"]
        digest.commands = ["swift test"]
        digest.finalMessage = "Done."
        digest.filesChanged = ["Sources/a.swift"]
        let request = FollowUpJob.request(digest: digest, mark: FollowUpMark(conversationID: "c", offset: 0), sessionName: "s",
                                          items: [], sessionItem: nil, sessionNotes: [], memoryIndex: nil,
                                          withTranscripts: false, model: .opus)
        XCTAssertFalse(request.call.input.contains("Store it per project"))
        XCTAssertFalse(request.call.input.contains("swift test"))
        XCTAssertTrue(request.call.input.contains("Done."))
        XCTAssertEqual(request.call.model, "opus")
        XCTAssertEqual(request.call.maxBudgetUSD, 1.5, accuracy: 0.0001)
    }

    func testSettingsFilesAreTolerant() throws {
        let settings = try JSONDecoder().decode(ProjectAssistantSettings.self,
                                                from: Data(#"{"quickModel":"someNewModel","dontSendTranscripts":true}"#.utf8))
        XCTAssertEqual(settings.quickModel, .haiku, "a model this build doesn't know falls back")
        XCTAssertTrue(settings.dontSendTranscripts)
        let app = try JSONDecoder().decode(AssistantAppSettings.self, from: Data(#"{"dailyJobLimit":5000}"#.utf8))
        XCTAssertEqual(app.dailyJobLimit, AssistantAppSettings.dailyJobLimitRange.upperBound, "clamped")
        XCTAssertEqual(try JSONDecoder().decode(AssistantAppSettings.self, from: Data("{}".utf8)).dailyJobLimit, 20)
    }

    // MARK: The audit log's reader

    func testTheAuditLogIsReadTolerantly() throws {
        let root = try makeTemporaryDirectory()
        let store = AssistantFileStore(root: root)
        let project = UUID()
        for index in 0..<3 {
            let job = AuditEntry.Job(name: "Promote check", model: "Haiku", subject: "s\(index)", succeeded: index != 1,
                                     failure: index == 1 ? "No answer came back." : nil)
            try store.appendAudit(AuditEntry(at: Date(), actor: .assistant, action: .jobRan, job: job, cause: "assistant"),
                                  projectID: project)
        }
        let url = root.appendingPathComponent(project.uuidString.lowercased()).appendingPathComponent("audit.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"action":"someNewAction","at":"2026-10-01T12:00:00Z"}"# + "\n").utf8))
        try handle.write(contentsOf: Data(#"{"action":"jobRan","at":"2026-10-01T12:"#.utf8))        // cut short
        try handle.close()
        let read = try store.readAudit(projectID: project, limit: 300)
        XCTAssertEqual(read.entries.compactMap(\.job?.subject), ["s0", "s1", "s2"])
        XCTAssertEqual(read.unreadable, 2, "a line from a later build and one cut short are skipped, not fatal")
        XCTAssertEqual(try store.readAudit(projectID: project, limit: 3).entries.compactMap(\.job?.subject), ["s2"],
                       "the newest lines only (the limit counts unreadable ones too)")
    }

    func testFailedCallsCanBeTriedAgainFromTheLog() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        let note = try await MainActor.run { () -> ProjectNote in
            try XCTUnwrap(f.model.addNote("A note", author: .user, projectID: f.project, sessionID: nil))
        }
        let job = AuditEntry.Job(name: PromoteCheck.job, model: "Haiku", subject: note.id.uuidString, succeeded: false,
                                 failure: "Claude Code is installed but not signed in.")
        assistant.audit[f.project, default: []].append(AuditEntry(at: AssistantQueueTests.now, actor: .assistant,
                                                                  action: .jobRan, job: job, cause: "assistant"))
        await MainActor.run {
            f.model.openAssistantLog(projectID: f.project)
            let row = f.model.assistantLog(forProject: f.project).first
            XCTAssertEqual(row?.result, .failed(message: "Claude Code is installed but not signed in.", retry: .noteCheck(noteID: note.id)))
            XCTAssertEqual(f.model.shownAssistantPanel, .activityLog(projectID: f.project))
            f.model.retry(row!.retry!, projectID: f.project)
        }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1, "Try Again checks the note again")
    }
}

extension AssistantQueueTests {
    // MARK: Review round 1 (PR #35)

    /// Try Again with the assistant off: no check, and never a promotion.
    func testTryAgainDoesNothingWhileTheAssistantIsOff() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        let note = try await MainActor.run { () -> ProjectNote in
            try XCTUnwrap(f.model.addNote("A note", author: .user, projectID: f.project, sessionID: nil))
        }
        let job = AuditEntry.Job(name: PromoteCheck.job, model: "Haiku", subject: note.id.uuidString, succeeded: false, failure: "x")
        assistant.audit[f.project, default: []].append(AuditEntry(at: AssistantQueueTests.now, actor: .assistant, action: .jobRan,
                                                                  job: job, cause: "assistant"))
        await MainActor.run {
            f.model.openAssistantLog(projectID: f.project)
            f.model.setAssistantMode(.off, projectID: f.project)
            XCTAssertNil(f.model.assistantLog(forProject: f.project).first?.retry, "Job Failed hides Try Again")
            XCTAssertFalse(f.model.retry(.noteCheck(noteID: note.id), projectID: f.project))
            XCTAssertEqual(f.model.toast?.text, "The assistant is off for this project")
            XCTAssertTrue(f.model.items(inProject: f.project).isEmpty, "not promoted to the plan")
            f.model.setAssistantMode(.automatic, projectID: f.project)
            f.model.promoteNote(note.id, projectID: f.project)
            XCTAssertFalse(f.model.retry(.noteCheck(noteID: note.id), projectID: f.project), "it's in the plan now")
            XCTAssertEqual(f.model.toast?.text, "That note has gone, or is in the plan now")
        }
        await f.model.waitForAssistantJobs()
        XCTAssertTrue(f.runner.calls.isEmpty)
    }

    /// An unreadable settings file keeps transcripts back, and isn't written over.
    func testUnreadableSettingsFailClosed() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        assistant.projectSettingsError = CocoaError(.fileReadCorruptFile)
        await MainActor.run {
            f.model.prepareAssistantFiles()
            XCTAssertTrue(f.model.assistantSettings(forProject: f.project).dontSendTranscripts, "privacy fails closed")
            XCTAssertTrue(f.model.unreadableProjectSettings.contains(f.project))
            var changed = f.model.assistantSettings(forProject: f.project)
            changed.quickModel = .opus
            f.model.setAssistantSettings(changed, projectID: f.project)
            XCTAssertNil(assistant.projectSettings[f.project], "the file isn't written over")
            XCTAssertNotNil(f.model.log.entries.last { $0.title.hasPrefix("Couldn't read the assistant's settings") })
        }
        let present = try JSONDecoder().decode(ProjectAssistantSettings.self, from: Data(#"{"dontSendTranscripts":"yes"}"#.utf8))
        XCTAssertTrue(present.dontSendTranscripts, "a value that's there but can't be read means don't send")
    }

    func testTheFileStoreKeepsSettings() throws {
        let store = AssistantFileStore(root: try makeTemporaryDirectory())
        let project = UUID()
        XCTAssertEqual(try store.loadProjectSettings(projectID: project), ProjectAssistantSettings(), "none yet: the defaults")
        var settings = ProjectAssistantSettings()
        settings.deepModel = .opus
        settings.dontSendTranscripts = true
        try store.saveProjectSettings(settings, projectID: project)
        XCTAssertEqual(try store.loadProjectSettings(projectID: project), settings)
        let url = store.directory(projectID: project).appendingPathComponent("settings.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.loadProjectSettings(projectID: project), "unreadable is an error, not the defaults")
    }

    /// One field that can't be read doesn't reset the others.
    func testAppSettingsDecodeFieldByField() throws {
        let app = try JSONDecoder().decode(AssistantAppSettings.self, from: Data(#"{"isEnabled":false,"dailyJobLimit":"x","pauseThreshold":5}"#.utf8))
        XCTAssertFalse(app.isEnabled, "the switch stays off")
        XCTAssertEqual(app.dailyJobLimit, 20)
        XCTAssertEqual(app.pauseThreshold, 50, "clamped")
        var edited = app
        edited.dailyJobLimit = 9999
        edited.pauseThreshold = 10
        XCTAssertEqual(edited.dailyJobLimit, AssistantAppSettings.dailyJobLimitRange.upperBound, "clamped in core, not only by the control")
        XCTAssertEqual(edited.pauseThreshold, 50)
    }

    func testAnUnreadableAuditLogIsReported() async throws {
        let assistant = MemoryAssistantStore()
        let f = try await makeFixture(assistant: assistant)
        assistant.auditReadError = CocoaError(.fileReadNoPermission)
        await MainActor.run {
            f.model.openAssistantLog(projectID: f.project)
            XCTAssertTrue(f.model.unreadableAssistantLogs.contains(f.project), "not shown as an empty log")
            XCTAssertNotNil(f.model.log.entries.last { $0.title.hasPrefix("Couldn't read the assistant's log") })
        }
    }

    func testAuditReadKeepsALineThatStartsTheWindow() throws {
        let root = try makeTemporaryDirectory()
        let store = AssistantFileStore(root: root)
        let project = UUID()
        let job = AuditEntry.Job(name: "Promote check", model: "Haiku", subject: "kept", succeeded: true)
        try store.appendAudit(AuditEntry(at: Date(), actor: .assistant, action: .jobRan, job: job, cause: "assistant"), projectID: project)
        XCTAssertEqual(try store.readAudit(projectID: project, limit: -1).entries.count, 0, "a negative limit is safe")
        XCTAssertEqual(try store.readAudit(projectID: project, limit: 300).entries.compactMap(\.job?.subject), ["kept"])
    }

    /// claude.ai users are held by the usage gate: waiting for the first
    /// reading, then over the threshold, then released by a low reading.
    func testAUsageReadingReleasesHeldWork() async throws {
        let runner = QueueRunner()
        runner.base.authOutput = #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}"#
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/code/app")
        let store = MemoryStore()
        store.state = state
        let model = await MainActor.run {
            AppModel(store: store, discovery: SessionDiscovery(claudeHome: try! makeTemporaryDirectory()),
                     hookEventsURL: try! makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, locateGitHubCLI: { nil }, shell: "/bin/sh",
                     now: { AssistantJobTests.beforeReset }, home: "/")
        }
        await model.checkEnvironment(force: true)
        try await MainActor.run {
            let note = try XCTUnwrap(model.addNote("Before any reading", author: .user, projectID: project, sessionID: nil))
            model.checkCapturedNote(note, projectID: project)
            XCTAssertEqual(model.heldJobs.first?.reason, "Waiting for a usage reading")
            XCTAssertEqual(model.assistantStatusLine(forProject: project), .paused(reason: "Waiting for a usage reading", waiting: 1))
        }
        runner.base.usageOutput = try Fixtures.string("usage-stream.jsonl").replacingOccurrences(of: #""percent":5"#, with: #""percent":90"#)
        await model.refreshUsage()
        await MainActor.run {
            XCTAssertEqual(model.heldJobs.count, 1, "still held: over the threshold")
            XCTAssertEqual(model.heldJobs.first?.reason.hasSuffix("90%"), true, model.heldJobs.first?.reason ?? "")
        }
        runner.base.usageOutput = try Fixtures.string("usage-stream.jsonl")
        await model.refreshUsage()
        await model.waitForAssistantJobs()
        XCTAssertEqual(runner.calls.count, 1, "released by the reading")
        let held = await MainActor.run { model.heldJobs }
        XCTAssertTrue(held.isEmpty)
    }

    /// The gate is checked before each release, and one job per project
    /// goes per pass.
    func testReleasesGoOneAtATimeWithinTheLimit() async throws {
        let f = try await makeFixture()
        try await MainActor.run {
            atDailyLimit(f)
            for text in ["First", "Second", "Third"] { _ = try capture(f, text) }
            var settings = f.model.settings
            settings.assistant.dailyJobLimit = f.model.settings.assistant.dailyJobLimit + 1
            f.model.updateSettings(settings)
            XCTAssertEqual(f.model.heldJobs.map(\.subject), ["Second", "Third"], "the oldest went; the limit holds the rest")
            f.model.releaseHeldJobs()
            XCTAssertEqual(f.model.heldJobs.count, 2, "still at the limit")
        }
        await f.model.waitForAssistantJobs()
        XCTAssertEqual(f.runner.calls.count, 1)
    }
}

@MainActor private final class Ran {
    var names: [String] = []
}
