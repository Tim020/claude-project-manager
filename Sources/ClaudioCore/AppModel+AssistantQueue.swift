import Foundation

// Step 4b of the Project Assistant: held-back background work, and the
// status line. A background job the usage gate holds back (over the
// threshold, spending credits, waiting for a first usage reading, or at the
// daily limit) waits here and runs once the gate opens; a newer job with
// the same key replaces it. Only what to do is kept, not a built request:
// the job looks at its subject again when it runs. The list lives in
// memory, so held jobs are lost on quit.

/// A background job waiting for the usage gate (design 9a: "Waiting").
public struct HeldJob: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// What it's about, so a newer job for the same thing replaces it
    /// ("notecheck:<note id>").
    public var key: String
    public var projectID: UUID
    /// "Promote check".
    public var job: String
    /// What it's about, in words ("Shell panel height resets…").
    public var subject: String
    public var heldAt: Date
    /// Why it's waiting ("5-hour usage 84%").
    public var reason: String
}

/// The Assistant panel's status line (design 9a): at most one shows.
public enum AssistantStatusLine: Equatable, Sendable {
    /// The project's mode is Off.
    case offInProject
    /// Settings › Assistant is off, in every project.
    case offEverywhere
    /// Automatic, but background work is held back.
    case paused(reason: String, waiting: Int)
    /// Manual: only what you ask for.
    case manual
}

extension AppModel {
    // MARK: - Holding and releasing

    /// Runs background work now if the gate allows (counting it against
    /// today's limit), holds it while the gate is paused or waiting for a
    /// usage reading, and drops it when the project is Off or Manual.
    /// `start` looks at its subject again, and returns whether it called
    /// Claude (only then is it counted).
    func runOrHoldBackground(key: String, projectID: UUID, job: String, subject: String,
                             start: @escaping @MainActor () -> Bool) {
        switch backgroundGate(forProject: projectID) {
        case .run:
            cancelHeldJob(key: key)
            if start() { countBackgroundJob() }
        case .paused(let reason):
            hold(HeldJob(key: key, projectID: projectID, job: job, subject: subject, heldAt: now(), reason: reason), start)
        case .waitingForUsage:
            hold(HeldJob(key: key, projectID: projectID, job: job, subject: subject, heldAt: now(),
                         reason: "Waiting for a usage reading"), start)
        case .off, .manual:
            cancelHeldJob(key: key)
        }
    }

    private func hold(_ job: HeldJob, _ start: @escaping @MainActor () -> Bool) {
        var jobs = heldJobs
        if let index = jobs.firstIndex(where: { $0.key == job.key }) {
            // The newer one takes its place, and its spot in the line.
            heldJobRuns[jobs[index].id] = nil
            var replacement = job
            replacement.heldAt = jobs[index].heldAt
            jobs[index] = replacement
        } else {
            jobs.append(job)
        }
        heldJobRuns[job.id] = start
        heldJobs = jobs
        log.append(.info, "Assistant: \(job.job) waiting (\(job.reason))")
    }

    /// Runs held jobs whose project's gate has opened, oldest first, checking
    /// the gate before each (so the daily limit can stop part-way); drops
    /// those whose project is now Off or Manual; and updates the reason on
    /// the rest. Called on each usage reading, settings change and 15 s tick.
    func releaseHeldJobs() {
        guard !heldJobs.isEmpty else { return }
        var remaining: [HeldJob] = []
        for var job in heldJobs {
            switch backgroundGate(forProject: job.projectID) {
            case .run:
                // Run now, so the next job's gate sees today's count.
                if let start = heldJobRuns.removeValue(forKey: job.id) {
                    heldJobs.removeAll { $0.id == job.id }
                    if start() { countBackgroundJob() }
                }
            case .paused(let reason):
                job.reason = reason
                remaining.append(job)
            case .waitingForUsage:
                job.reason = "Waiting for a usage reading"
                remaining.append(job)
            case .off, .manual:
                heldJobRuns[job.id] = nil
            }
        }
        if remaining != heldJobs { heldJobs = remaining }
    }

    /// Removes a held job (when what it's for has gone, or you started the
    /// same thing yourself).
    func cancelHeldJob(key: String) {
        guard let job = heldJobs.first(where: { $0.key == key }) else { return }
        heldJobRuns[job.id] = nil
        heldJobs.removeAll { $0.key == key }
    }

    /// Off or Manual (the project, or Settings › Assistant): held work is
    /// dropped and open follow-up offers are withdrawn.
    func assistantStoppedBackgroundWork(inProject projectID: UUID) {
        for job in heldJobs where job.projectID == projectID { heldJobRuns[job.id] = nil }
        if heldJobs.contains(where: { $0.projectID == projectID }) { heldJobs.removeAll { $0.projectID == projectID } }
        let offers = needsYouData(inProject: projectID).followUps.filter { $0.state == .offered }
        guard !offers.isEmpty else { return }
        for offer in offers { pendingDigests[offer.id] = nil }
        updateNeedsYou(projectID) { data in data.followUps.removeAll { $0.state == .offered } }
    }

    /// After Settings › Assistant changes: turning it off stops background
    /// work everywhere; anything else (the threshold, credits, the daily
    /// limit) may let held work run.
    func assistantSettingsChanged(from old: AssistantAppSettings, to new: AssistantAppSettings) {
        guard old != new else { return }
        if old.isEnabled && !new.isEnabled {
            for project in workspace.projects { assistantStoppedBackgroundWork(inProject: project.id) }
        } else {
            releaseHeldJobs()
        }
    }

    public func heldJobs(inProject projectID: UUID) -> [HeldJob] {
        heldJobs.filter { $0.projectID == projectID }
    }

    // MARK: - The status line

    /// Off (the project's, or everywhere), paused with how many wait, or
    /// Manual; nil when it's Automatic and running.
    public func assistantStatusLine(forProject projectID: UUID) -> AssistantStatusLine? {
        guard settings.assistant.isEnabled else { return .offEverywhere }
        switch assistantMode(ofProject: projectID) {
        case .off: return .offInProject
        case .manual: return .manual
        case .automatic:
            switch backgroundGate(forProject: projectID) {
            case .paused(let reason): return .paused(reason: reason, waiting: heldJobs(inProject: projectID).count)
            case .waitingForUsage:
                let waiting = heldJobs(inProject: projectID).count
                return waiting == 0 ? nil : .paused(reason: "Waiting for a usage reading", waiting: waiting)
            default: return nil
            }
        }
    }

    /// Turn On, on the Off card: the project's mode back to Automatic, or
    /// Settings › Assistant back on.
    public func turnAssistantOn(inProject projectID: UUID) {
        if !settings.assistant.isEnabled {
            var settings = self.settings
            settings.assistant.isEnabled = true
            updateSettings(settings)
        } else if assistantMode(ofProject: projectID) == .off {
            setAssistantMode(.automatic, projectID: projectID)
        }
    }
}
