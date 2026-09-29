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

extension AppModel {
    /// How many assistant calls run at once.
    public static let maxAssistantJobs = 2
    /// How long a call may take (the runner's timeout).
    public static let assistantJobTimeout = 60

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
        return .run
    }

    /// "5-hour usage 84%" while a window is at or over the threshold, or
    /// "Using credits" while credits are being spent (unless allowed).
    public var usagePauseReason: String? {
        guard let usage = usage?.current(at: now()) else { return nil }
        let threshold = Double(settings.assistant.pauseThreshold)
        if let window = usage.fiveHour, window.usedPercentage >= threshold {
            return "5-hour usage \(Int(window.usedPercentage.rounded()))%"
        }
        if let window = usage.sevenDay, window.usedPercentage >= threshold {
            return "Weekly usage \(Int(window.usedPercentage.rounded()))%"
        }
        if usage.isUsingCredits && !settings.assistant.allowWhileUsingCredits { return "Using credits" }
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
        checkNote(note, projectID: projectID, askedFor: true)
    }

    /// After a capture: in Automatic mode, check the note against the plan.
    /// Skipped, not queued, when the gate says no (the note keeps its
    /// Promote… link): an exception to "held-back work waits", because the
    /// check is only useful while the note is fresh.
    func checkCapturedNote(_ note: ProjectNote, projectID: UUID) {
        guard backgroundGate(forProject: projectID) == .run else { return }
        checkNote(note, projectID: projectID, askedFor: false)
    }

    /// Keep as Note: dismisses the suggestion.
    public func keepAsNote(_ noteID: UUID) {
        clearNoteSuggestion(noteID)
    }

    private func checkNote(_ note: ProjectNote, projectID: UUID, askedFor: Bool) {
        guard noteSuggestions[note.id] != .checking else { return }
        noteSuggestions[note.id] = .checking
        let call = PromoteCheck.call(note: note, items: items(inProject: projectID))
        runAssistantJob(call, projectID: projectID, subject: note.id.uuidString) { [weak self] result in
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
                let suggestion = PromoteCheck.suggestion(from: reply.output, note: current, items: self.items(inProject: projectID),
                                                         askedFor: askedFor)
                if let suggestion { self.noteSuggestions[note.id] = suggestion } else { self.clearNoteSuggestion(note.id) }
            case .failure(let failure):
                self.clearNoteSuggestion(note.id)
                // Only something you asked for says so (step 4 brings the
                // Needs You card for background failures).
                if askedFor { self.report(failure.message) }
            }
        }
    }

    // MARK: - Running calls

    /// Runs an assistant call when a slot is free, records it in the audit
    /// log and the Activity Log, and hands its result back on the main actor.
    func runAssistantJob(_ call: AssistantCall, projectID: UUID, subject: String,
                         completion: @escaping @MainActor (Result<AssistantReply, AssistantFailure>) -> Void) {
        assistantJobQueue.append { [weak self] in
            guard let self else { return }
            let result = await self.performAssistantCall(call)
            self.recordJob(call, projectID: projectID, subject: subject, result: result)
            completion(result)
        }
        startQueuedAssistantJobs()
    }

    private func startQueuedAssistantJobs() {
        while assistantJobsRunning < AppModel.maxAssistantJobs, !assistantJobQueue.isEmpty {
            let job = assistantJobQueue.removeFirst()
            assistantJobsRunning += 1
            assistantJobTasks.append(Task { @MainActor [weak self] in
                await job()
                guard let self else { return }
                self.assistantJobsRunning -= 1
                self.startQueuedAssistantJobs()
            })
        }
    }

    /// Waits for every assistant call started so far (for tests).
    func waitForAssistantJobs() async {
        while let task = assistantJobTasks.first {
            assistantJobTasks.removeFirst()
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
        return AssistantReplyParser.parse(result, timeout: AppModel.assistantJobTimeout)
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
        } catch {
            log.append(.error, "Couldn't record an assistant call", detail: AppModel.describe(error))
        }
    }
}
