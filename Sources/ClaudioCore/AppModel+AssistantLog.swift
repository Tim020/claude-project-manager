import Foundation

// Step 4b of the Project Assistant: the Assistant's Activity Log (design
// 9a): every Claude call in a project, newest first, as Done or Failed (from
// `audit.jsonl`'s job entries), with held-back work at the top as Waiting
// (from the held list in memory, never from the log). It's the audit log's
// first reader, so lines it can't decode are skipped and counted.

/// One row of the Assistant's Activity Log.
public struct AssistantLogRow: Identifiable, Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case done(durationMS: Int?, costUSD: Double?)
        case waiting(reason: String)
        case failed(message: String)
    }

    public var id: UUID
    public var at: Date
    /// "Promote check", "Follow-up".
    public var job: String
    /// What it was about, in words: a note's opening words, a session's name.
    public var subject: String
    public var model: String
    public var result: Result
    /// What Try Again does, where it can.
    public var retry: AssistantRetry?

    public init(id: UUID, at: Date, job: String, subject: String, model: String, result: Result, retry: AssistantRetry?) {
        self.id = id
        self.at = at
        self.job = job
        self.subject = subject
        self.model = model
        self.result = result
        self.retry = retry
    }
}

/// What Try Again on a failed call does.
public enum AssistantRetry: Equatable, Sendable {
    /// Check the note against the plan again.
    case noteCheck(noteID: UUID)
    /// Review the session again.
    case followUp(sessionID: UUID)
}

extension AppModel {
    /// How many of the newest log lines the view reads.
    public static let assistantLogLimit = 300

    /// The rows for a project's Activity Log: waiting work first, then the
    /// calls it has made, newest first. Read when the view opens (and kept
    /// in `assistantLogRows`), not in a view's body.
    public func refreshAssistantLog(projectID: UUID) {
        let (entries, unreadable) = assistantStore.readAudit(projectID: projectID, limit: AppModel.assistantLogLimit)
        if unreadable > 0, assistantLogUnreadable[projectID] != unreadable {
            log.append(.error, "\(unreadable) of the assistant's log lines for \(workspace.project(projectID)?.name ?? "a project") couldn't be read",
                       detail: "They're skipped in its Activity Log. They may be from a newer Claudio, or cut short.")
        }
        assistantLogUnreadable[projectID] = unreadable
        let rows = entries.compactMap { logRow(for: $0, projectID: projectID) }.reversed()
        let updated = Array(rows)
        if assistantLogRows[projectID] != updated { assistantLogRows[projectID] = updated }
    }

    /// Waiting work, then the calls made (as last read), newest first.
    public func assistantLog(forProject projectID: UUID) -> [AssistantLogRow] {
        let waiting = heldJobs(inProject: projectID).reversed().map { job in
            AssistantLogRow(id: job.id, at: job.heldAt, job: job.job, subject: job.subject,
                            model: AssistantModels.displayName(assistantSettings(forProject: projectID).quickModel.rawValue),
                            result: .waiting(reason: job.reason), retry: nil)
        }
        return waiting + (assistantLogRows[projectID] ?? [])
    }

    /// A job entry as a row; other entries (note and item changes) aren't calls.
    private func logRow(for entry: AuditEntry, projectID: UUID) -> AssistantLogRow? {
        guard entry.action == .jobRan, let job = entry.job else { return nil }
        let (subject, retry) = describe(subject: job.subject, job: job.name, projectID: projectID)
        let result: AssistantLogRow.Result = job.succeeded
            ? .done(durationMS: job.durationMS, costUSD: job.costUSD)
            : .failed(message: job.failure ?? "It failed.")
        return AssistantLogRow(id: entry.id, at: entry.at, job: job.name, subject: subject, model: job.model, result: result,
                               retry: job.succeeded ? nil : retry)
    }

    /// A job's subject (an id) in words, and how to try it again. Falls
    /// back when what it was about has gone.
    func describe(subject: String, job: String, projectID: UUID) -> (String, AssistantRetry?) {
        guard let id = UUID(uuidString: subject) else { return (subject, nil) }
        if job == PromoteCheck.job {
            guard let note = assistantData[projectID]?.notes.first(where: { $0.id == id }) else { return ("A note that's gone", nil) }
            return (PlanTitle.from(note.text), note.itemID == nil ? .noteCheck(noteID: id) : nil)
        }
        if job == FollowUpJob.job {
            if let session = workspace.session(id) { return (session.name, .followUp(sessionID: id)) }
            return ("A session that's gone", nil)
        }
        return (subject, nil)
    }

    /// Try Again on a failed call.
    public func retry(_ retry: AssistantRetry, projectID: UUID) {
        switch retry {
        case .noteCheck(let noteID): recheckNote(noteID, projectID: projectID)
        case .followUp(let sessionID):
            if let failed = needsYouData(inProject: projectID).followUps.last(where: {
                guard $0.sessionID == sessionID, case .failed = $0.state else { return false }
                return true
            }) {
                retryFollowUp(failed.id, projectID: projectID)
            } else {
                reviewSession(sessionID)
            }
        }
    }
}
