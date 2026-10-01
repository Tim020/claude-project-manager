import Foundation

// The assistant's Claude calls (design: `design/Project Assistant
// Backend.md`, Runtime). Code decides whether a call is worth making; the
// reply only ever becomes a suggestion you answer.

/// Whether the assistant may work in a project right now.
public enum AssistantGate: Equatable, Sendable {
    /// Background work may run.
    case run
    /// Settings › Assistant is off, or the project's mode is Off: no calls at all.
    case off
    /// Manual mode: only what you ask for.
    case manual
    /// Over the usage threshold, or spending credits ("5-hour usage 84%").
    case paused(String)
    /// A plan-usage reading is expected but hasn't come yet.
    case waitingForUsage
}

/// An assistant call waiting for a slot.
struct QueuedAssistantJob {
    var key: String?
    var projectID: UUID
    /// Background work: one at a time per project. Things you start only
    /// wait for the overall limit, never behind a background call.
    var isBackground: Bool
    var work: @MainActor () async -> Void
}

extension AppModel {
    /// How many assistant calls run at once.
    public static let maxAssistantJobs = 2

    // MARK: - The gate

    /// Whether the assistant is on for a project at all: Settings ›
    /// Assistant, and the project's mode.
    public func isAssistantOn(inProject projectID: UUID) -> Bool {
        settings.assistant.isEnabled && assistantMode(ofProject: projectID) != .off
    }

    /// Whether background work (such as checking a note you've just
    /// captured) may call Claude now. Things you start yourself don't ask.
    public func backgroundGate(forProject projectID: UUID) -> AssistantGate {
        guard isAssistantOn(inProject: projectID) else { return .off }
        guard assistantMode(ofProject: projectID) == .automatic else { return .manual }
        if let reason = usagePauseReason { return .paused(reason) }
        if usage == nil && expectsUsageReading { return .waitingForUsage }
        // Without a plan-usage reading, the daily limit is the only cap.
        if !expectsUsageReading, backgroundJobsToday >= settings.assistant.dailyJobLimit {
            return .paused("Daily limit of \(settings.assistant.dailyJobLimit) reached")
        }
        return .run
    }

    /// Background calls made today.
    var backgroundJobsToday: Int {
        let today = DailyJobCount.day(of: now())
        if dailyJobs == nil {
            if let saved = assistantStore.loadDailyJobs() {
                dailyJobs = saved
            } else {
                // None yet, or a file that can't be read: start today at 0
                // (kept, so it isn't read again on every check).
                if assistantStore.hasDailyJobsFile() {
                    log.append(.error, "Couldn't read today's count of assistant calls, so it starts again at 0")
                }
                dailyJobs = DailyJobCount(day: today, count: 0)
            }
        }
        return dailyJobs?.day == today ? dailyJobs?.count ?? 0 : 0
    }

    /// Counts a background call against today's limit.
    func countBackgroundJob() {
        let today = DailyJobCount.day(of: now())
        let count = DailyJobCount(day: today, count: backgroundJobsToday + 1)
        dailyJobs = count
        do {
            try assistantStore.saveDailyJobs(count)
        } catch {
            log.append(.error, "Couldn't save today's count of assistant calls", detail: AppModel.describe(error))
        }
    }

    /// "Using credits" while credits are being spent (unless that's
    /// allowed), else "5-hour usage 84%" while a window is at or over the
    /// threshold. Credits come first: they're spent when a window is full,
    /// which is over any threshold, so otherwise the setting could never
    /// let work run.
    public var usagePauseReason: String? {
        guard let usage = usage?.current(at: now()) else { return nil }
        if usage.isUsingCredits {
            return settings.assistant.allowWhileUsingCredits ? nil : "Using credits"
        }
        let threshold = Double(settings.assistant.pauseThreshold)
        if let window = usage.fiveHour, window.usedPercentage >= threshold {
            return "5-hour usage \(Int(window.usedPercentage.rounded()))%"
        }
        if let window = usage.sevenDay, window.usedPercentage >= threshold {
            return "Weekly usage \(Int(window.usedPercentage.rounded()))%"
        }
        return nil
    }

    /// Plan usage is read for claude.ai plans. API keys and cloud providers
    /// never get a reading, so for them the gate doesn't wait for one.
    var expectsUsageReading: Bool {
        switch environment.signIn {
        case .signedIn(let status): return status.plan != nil
        case .unchecked: return true
        case .signedOut, .unknown: return false
        }
    }

    /// The note shown on things you start while usage is high:
    /// "5-hour usage is 84%. Things you start still run."
    public var usageHighNote: String? {
        usagePauseReason.map { reason in
            reason == "Using credits" ? "Using credits. Things you start still run."
                : reason.replacingOccurrences(of: " usage ", with: " usage is ") + ". Things you start still run."
        }
    }

    // MARK: - Promote

    /// Promote… on a note. With the assistant off, it makes an Idea from
    /// the note straight away. Otherwise it checks the note against the plan
    /// and shows what it suggests, whatever the usage.
    public func requestPromote(_ noteID: UUID, projectID: UUID) {
        guard let note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.itemID == nil else { return }
        guard isAssistantOn(inProject: projectID) else {
            promoteNote(noteID, projectID: projectID, status: .idea)
            return
        }
        // You asked: a check of it waiting for the gate isn't needed now.
        cancelHeldJob(key: AppModel.noteCheckKey(noteID))
        checkNote(note, projectID: projectID, askedFor: true)
    }

    /// After a capture: in Automatic mode, check the note against the plan.
    /// While the gate holds background work back, the check waits and runs
    /// once it opens (step 4b; step 2 skipped it). When it runs, the note
    /// must still be there, without a plan item or a suggestion.
    func checkCapturedNote(_ note: ProjectNote, projectID: UUID) {
        runOrHoldBackground(key: AppModel.noteCheckKey(note.id), projectID: projectID, job: PromoteCheck.job,
                            subject: PlanTitle.from(note.text)) { [weak self] in
            guard let self,
                  let current = self.assistantData[projectID]?.notes.first(where: { $0.id == note.id }),
                  current.itemID == nil, self.noteSuggestions[note.id] == nil
            else { return false }
            self.checkNote(current, projectID: projectID, askedFor: false)
            return true
        }
    }

    static func noteCheckKey(_ noteID: UUID) -> String { "notecheck:\(noteID.uuidString.lowercased())" }

    /// Keep as Note: dismisses the suggestion.
    public func keepAsNote(_ noteID: UUID) {
        clearNoteSuggestion(noteID)
    }

    /// Check Again, on a suggestion or from a note's menu: asks afresh, as
    /// Promote… does. The new answer replaces the old one; if the check
    /// fails, the old one comes back.
    public func recheckNote(_ noteID: UUID, projectID: UUID) {
        requestPromote(noteID, projectID: projectID)
    }

    private func checkNote(_ note: ProjectNote, projectID: UUID, askedFor: Bool) {
        let previous = noteSuggestions[note.id]
        guard previous != .checking else { return }
        setNoteSuggestion(.checking, for: note.id)
        let request = PromoteCheck.request(note: note, items: items(inProject: projectID),
                                           model: assistantSettings(forProject: projectID).quickModel)
        runAssistantJob(request.call, projectID: projectID, subject: note.id.uuidString, isBackground: !askedFor) {
            [weak self] result in
            guard let self else { return }
            // The note may have gone, or been promoted by hand, meanwhile.
            guard self.noteSuggestions[note.id] == .checking,
                  let current = self.assistantData[projectID]?.notes.first(where: { $0.id == note.id }), current.itemID == nil
            else {
                if self.noteSuggestions[note.id] == .checking { self.clearNoteSuggestion(note.id) }
                return
            }
            switch result {
            case .success(let reply):
                // Refs as they were when the call was made; the item must
                // still be in the plan, and not done, to be suggested.
                let suggestion = PromoteCheck.suggestion(from: reply.output, note: current, refs: request.refs,
                                                         items: self.items(inProject: projectID), askedFor: askedFor)
                self.setNoteSuggestion(suggestion, for: note.id)
            case .failure(let failure):
                // A failed Check Again leaves the earlier answer in place.
                self.setNoteSuggestion(previous, for: note.id)
                // Only something you asked for says so (4b brings the Job
                // Failed view for background failures).
                if askedFor { self.report(failure.message) }
            }
        }
    }

    // MARK: - Running calls

    /// Runs an assistant call when a slot is free, records it in the audit
    /// log and the Activity Log, and hands its result back on the main actor.
    /// At most two run at once, and one background call per project. `key`:
    /// a newer job with the same key replaces one still waiting (its
    /// completion isn't called).
    func runAssistantJob(_ call: AssistantCall, projectID: UUID, subject: String, key: String? = nil,
                         isBackground: Bool = false,
                         completion: @escaping @MainActor (Result<AssistantReply, AssistantFailure>) -> Void) {
        let job = QueuedAssistantJob(key: key, projectID: projectID, isBackground: isBackground) { [weak self] in
            guard let self else { return }
            let result = await self.performAssistantCall(call)
            self.recordJob(call, projectID: projectID, subject: subject, result: result)
            completion(result)
        }
        if let key, let index = assistantJobQueue.firstIndex(where: { $0.key == key }) {
            assistantJobQueue[index] = job
        } else {
            assistantJobQueue.append(job)
        }
        startQueuedAssistantJobs()
    }

    /// Whether a job with this key is waiting (not yet running).
    func isAssistantJobQueued(key: String) -> Bool {
        assistantJobQueue.contains { $0.key == key }
    }

    private func startQueuedAssistantJobs() {
        while assistantJobsRunning < AppModel.maxAssistantJobs,
              let index = assistantJobQueue.firstIndex(where: { !$0.isBackground || !assistantBackgroundProjects.contains($0.projectID) }) {
            let job = assistantJobQueue.remove(at: index)
            assistantJobsRunning += 1
            if job.isBackground { assistantBackgroundProjects.insert(job.projectID) }
            let id = UUID()
            assistantJobTasks[id] = Task { @MainActor [weak self] in
                await job.work()
                guard let self else { return }
                self.assistantJobsRunning -= 1
                if job.isBackground { self.assistantBackgroundProjects.remove(job.projectID) }
                // Finished, so it's no longer held.
                self.assistantJobTasks[id] = nil
                self.startQueuedAssistantJobs()
            }
        }
    }

    /// Waits until no assistant call is running or waiting (for tests).
    func waitForAssistantJobs() async {
        while let task = assistantJobTasks.values.first {
            await task.value
        }
    }

    private func performAssistantCall(_ call: AssistantCall) async -> Result<AssistantReply, AssistantFailure> {
        guard let commands = agentCommands(reportErrors: false) else { return .failure(.claudeMissing) }
        let directory = assistantStore.runsDirectory()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ClaudioAssistant")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let userSettings = (try? Data(contentsOf: discovery.claudeHome.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let launch = commands.assistant(call, in: directory.path, settingSources: AssistantSettingSources.value(userSettings: userSettings))
        // The output holds the note and the reply, so it isn't logged.
        let result = await run(launch, hideOutput: true)
        let parsed = AssistantReplyParser.parse(result, timeout: call.timeout, budget: call.maxBudgetUSD)
        if case .failure(.invalidReply) = parsed {
            // The output is hidden (it holds the note), so say what shape it had.
            log.append(.error, "Assistant: \(call.job) gave a reply Claudio couldn't use",
                       detail: AssistantReplyParser.summary(of: result.output))
        }
        return parsed
    }

    private func recordJob(_ call: AssistantCall, projectID: UUID, subject: String, result: Result<AssistantReply, AssistantFailure>) {
        let model = AssistantModels.displayName(call.model)
        var job = AuditEntry.Job(name: call.job, model: model, subject: subject, succeeded: true)
        switch result {
        case .success(let reply):
            job.durationMS = reply.durationMS
            job.costUSD = reply.costUSD
            let seconds = reply.durationMS.map { String(format: "%.1f s", Double($0) / 1000) } ?? ""
            log.append(.info, "Assistant: \(call.job) (\(model)\(seconds.isEmpty ? "" : ", \(seconds)"))")
        case .failure(let failure):
            job.succeeded = false
            job.failure = failure.message
            log.append(.error, "Assistant: \(call.job) failed", detail: failure.message)
        }
        do {
            try assistantStore.appendAudit(AuditEntry(at: now(), actor: .assistant, action: .jobRan, job: job, cause: "assistant"),
                                           projectID: projectID)
            // An Activity Log that's been opened shows it.
            if assistantLogRows[projectID] != nil { refreshAssistantLog(projectID: projectID) }
        } catch {
            log.append(.error, "Couldn't record an assistant call", detail: AppModel.describe(error))
        }
    }
}
