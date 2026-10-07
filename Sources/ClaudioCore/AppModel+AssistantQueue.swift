import Foundation

// Step 4b of the Project Assistant: held-back background work, and the
// status line. A background job the usage gate holds back (over the
// threshold, spending credits, waiting for a first usage reading, or at the
// daily limit) waits here and runs once the gate opens; a newer job with
// the same key replaces it. Only what to do is kept, not a built request:
// the job looks at its subject again when it runs. The list lives in
// memory, so held jobs are lost on quit.

/// What a held job is for, so a newer one for the same thing replaces it.
/// Typed, so every place builds the same key.
public enum HeldJobKey: Hashable, Sendable {
    case noteCheck(UUID)
    case followUp(UUID)
    /// Drafting a skill from a lesson (a candidate's id).
    case skillDraft(UUID)

    /// For the app's Activity Log: an id, never the note's, session's or
    /// lesson's words (step 2 keeps note text out of that log).
    var logDetail: String {
        switch self {
        case .noteCheck(let id): return "note \(id.uuidString.lowercased())"
        case .followUp(let id): return "session \(id.uuidString.lowercased())"
        case .skillDraft(let id): return "lesson \(id.uuidString.lowercased())"
        }
    }
}

/// A background job waiting for the usage gate (design 9a: "Waiting").
public struct HeldJob: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var key: HeldJobKey
    public var projectID: UUID
    /// "Promote check".
    public var job: String
    /// What it's about, in words ("Shell panel height resets…").
    public var subject: String
    /// The model it will use ("Haiku"), for the Activity Log.
    public var model: String
    public var heldAt: Date
    /// Why it's waiting ("5-hour usage 84%").
    public var reason: String
}

/// A held job and what it does when it runs: kept together, so they can't
/// get out of step.
struct HeldJobEntry {
    var job: HeldJob
    /// Looks at the subject again and starts the call; true if it called Claude.
    var run: @MainActor () -> Bool
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
    /// The held jobs, oldest first.
    public var heldJobs: [HeldJob] { heldJobEntries.map(\.job) }

    // MARK: - Holding and releasing

    /// Runs background work now if the gate allows (counting it against
    /// today's limit), holds it while the gate is paused or waiting for a
    /// usage reading, and drops it when the project is Off or Manual.
    /// `start` looks at its subject again, and returns whether it called
    /// Claude (only then is it counted).
    func runOrHoldBackground(key: HeldJobKey, projectID: UUID, job: String, subject: String, model: String,
                             start: @escaping @MainActor () -> Bool) {
        switch backgroundGate(forProject: projectID) {
        case .run:
            cancelHeldJob(key: key)
            if start() { countBackgroundJob() }
        case .paused(let reason):
            hold(HeldJob(key: key, projectID: projectID, job: job, subject: subject, model: model, heldAt: now(), reason: reason),
                 start)
        case .waitingForUsage:
            hold(HeldJob(key: key, projectID: projectID, job: job, subject: subject, model: model, heldAt: now(),
                         reason: "Waiting for a usage reading"), start)
        case .off, .manual:
            cancelHeldJob(key: key)
        }
    }

    private func hold(_ job: HeldJob, _ start: @escaping @MainActor () -> Bool) {
        var entries = heldJobEntries
        if let index = entries.firstIndex(where: { $0.job.key == job.key }) {
            // The newer one takes its place, and its spot in the line.
            var replacement = job
            replacement.heldAt = entries[index].job.heldAt
            entries[index] = HeldJobEntry(job: replacement, run: start)
        } else {
            entries.append(HeldJobEntry(job: job, run: start))
        }
        heldJobEntries = entries
        log.append(.info, "Assistant: \(job.job) waiting (\(job.reason))", detail: job.key.logDetail)
    }

    /// Runs the oldest held job of each project whose gate has opened (one
    /// per project per pass, so usage is read again before the next), drops
    /// those whose project is now Off or Manual, and updates the reason on
    /// the rest. Called on each usage reading, Settings › Assistant change
    /// and 15 s tick. The gate is checked again just before each released
    /// job runs, since the daily limit is app-wide: one that's no longer
    /// allowed goes back to its place in the line.
    func releaseHeldJobs() {
        guard !heldJobEntries.isEmpty else { return }
        var remaining: [HeldJobEntry] = []
        var released: [HeldJobEntry] = []
        var releasedProjects = Set<UUID>()
        var dropped = 0
        for var entry in heldJobEntries {
            switch backgroundGate(forProject: entry.job.projectID) {
            case .run where !releasedProjects.contains(entry.job.projectID):
                releasedProjects.insert(entry.job.projectID)
                released.append(entry)
            case .run:
                remaining.append(entry)
            case .paused(let reason):
                entry.job.reason = reason
                remaining.append(entry)
            case .waitingForUsage:
                entry.job.reason = "Waiting for a usage reading"
                remaining.append(entry)
            case .off, .manual:
                dropped += 1
            }
        }
        // Assigned before anything runs, so a job held meanwhile isn't lost.
        if remaining.map(\.job) != heldJobs || remaining.count != heldJobEntries.count { heldJobEntries = remaining }
        if dropped > 0 { log.append(.info, "Assistant: dropped \(dropped) waiting job\(dropped == 1 ? "" : "s") (turned off)") }
        for entry in released {
            guard backgroundGate(forProject: entry.job.projectID) == .run else {
                // Another project's job used up what was left of today.
                var entries = heldJobEntries
                let index = entries.firstIndex { $0.job.heldAt > entry.job.heldAt } ?? entries.endIndex
                entries.insert(entry, at: index)
                heldJobEntries = entries
                continue
            }
            if entry.run() {
                countBackgroundJob()
            } else {
                log.append(.info, "Assistant: \(entry.job.job) skipped: no longer needed", detail: entry.job.key.logDetail)
            }
        }
    }

    /// Removes a held job (when what it's for has gone, or you started the
    /// same thing yourself).
    func cancelHeldJob(key: HeldJobKey) {
        guard heldJobEntries.contains(where: { $0.job.key == key }) else { return }
        heldJobEntries.removeAll { $0.job.key == key }
    }

    /// Off or Manual (the project, or Settings › Assistant): held work is
    /// dropped and open follow-up offers are withdrawn. A lesson whose draft
    /// was held becomes an offer in Manual; in Off, offers to draft go too.
    func assistantStoppedBackgroundWork(inProject projectID: UUID, because reason: String) {
        let held = heldJobEntries.filter { $0.job.projectID == projectID }.count
        if held > 0 { heldJobEntries.removeAll { $0.job.projectID == projectID } }
        if isAssistantOn(inProject: projectID) {
            considerSkillCandidates(projectID: projectID)
        } else {
            withdrawSkillOffers(inProject: projectID)
        }
        let offers = needsYouData(inProject: projectID).followUps.filter { $0.state == .offered }
        if !offers.isEmpty {
            for offer in offers { pendingDigests[offer.id] = nil }
            updateNeedsYou(projectID) { data in data.followUps.removeAll { $0.state == .offered } }
        }
        guard held > 0 || !offers.isEmpty else { return }
        let name = workspace.project(projectID)?.name ?? "a project"
        let parts = [held > 0 ? "\(held) waiting job\(held == 1 ? "" : "s")" : nil,
                     offers.isEmpty ? nil : "\(offers.count) follow-up offer\(offers.count == 1 ? "" : "s")"].compactMap { $0 }
        log.append(.info, "Assistant: dropped \(parts.joined(separator: " and ")) in \(name) (\(reason))")
    }

    /// After Settings › Assistant changes: turning it off stops background
    /// work everywhere; anything else (the threshold, credits, the daily
    /// limit) may let held work run.
    func assistantSettingsChanged(from old: AssistantAppSettings, to new: AssistantAppSettings) {
        guard old != new else { return }
        if old.isEnabled && !new.isEnabled {
            for project in workspace.projects { assistantStoppedBackgroundWork(inProject: project.id, because: "the assistant was turned off") }
        } else {
            releaseHeldJobs()
            // Back on: lessons whose offers were withdrawn are offered (or drafted) again.
            if !old.isEnabled && new.isEnabled {
                for project in workspace.projects { considerSkillCandidates(projectID: project.id) }
            }
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
