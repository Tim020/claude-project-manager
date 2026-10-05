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
        /// `retry`: what Try Again does, where it can (nil while the
        /// assistant is off, or when what it was about has gone).
        case failed(message: String, retry: AssistantRetry?)
    }

    public var id: UUID
    public var at: Date
    /// "Promote check", "Follow-up".
    public var job: String
    /// What it was about, in words: a note's opening words, a session's name.
    public var subject: String
    public var model: String
    public var result: Result

    public init(id: UUID, at: Date, job: String, subject: String, model: String, result: Result) {
        self.id = id
        self.at = at
        self.job = job
        self.subject = subject
        self.model = model
        self.result = result
    }

    public var retry: AssistantRetry? {
        if case .failed(_, let retry) = result { return retry }
        return nil
    }
}

/// What Try Again on a failed call does.
public enum AssistantRetry: Equatable, Sendable {
    /// Check the note against the plan again.
    case noteCheck(noteID: UUID)
    /// Review the session again.
    case followUp(sessionID: UUID)
    /// Draft a skill from the lesson again.
    case skillDraft(candidateID: UUID)
}

extension AppModel {
    /// How many of the newest log lines the view reads.
    public static let assistantLogLimit = 300

    /// Reads a project's Activity Log (kept in `assistantLogRows`): when the
    /// view opens, and after each call once it has. Not from a view's body.
    public func refreshAssistantLog(projectID: UUID) {
        let name = workspace.project(projectID)?.name ?? "a project"
        let read: (entries: [AuditEntry], unreadable: Int)
        do {
            read = try assistantStore.readAudit(projectID: projectID, limit: AppModel.assistantLogLimit)
            unreadableAssistantLogs.remove(projectID)
        } catch {
            if !unreadableAssistantLogs.contains(projectID) {
                log.append(.error, "Couldn't read the assistant's log for \(name)", detail: AppModel.describe(error))
            }
            unreadableAssistantLogs.insert(projectID)
            if assistantLogRows[projectID] == nil { assistantLogRows[projectID] = [] }
            return
        }
        if read.unreadable > 0, assistantLogUnreadable[projectID] != read.unreadable {
            log.append(.error, "\(read.unreadable) of the assistant's log lines for \(name) couldn't be read",
                       detail: "They're skipped in its Activity Log. They may be from a newer Claudio, or cut short.")
        }
        if assistantLogUnreadable[projectID] != read.unreadable { assistantLogUnreadable[projectID] = read.unreadable }
        let rows = Array(read.entries.compactMap { logRow(for: $0, projectID: projectID) }.reversed())
        if assistantLogRows[projectID] != rows { assistantLogRows[projectID] = rows }
    }

    /// Waiting work, then the calls made (as last read), newest first.
    public func assistantLog(forProject projectID: UUID) -> [AssistantLogRow] {
        let waiting = heldJobs(inProject: projectID).reversed().map { job in
            AssistantLogRow(id: job.id, at: job.heldAt, job: job.job, subject: job.subject, model: job.model,
                            result: .waiting(reason: job.reason))
        }
        // Retries depend on whether the assistant is on now, so the rows
        // read earlier are checked again.
        let on = isAssistantOn(inProject: projectID)
        let past = (assistantLogRows[projectID] ?? []).map { row -> AssistantLogRow in
            guard !on, case .failed(let message, _?) = row.result else { return row }
            var row = row
            row.result = .failed(message: message, retry: nil)
            return row
        }
        return waiting + past
    }

    /// How many log lines couldn't be read, for the view to say so.
    public func unreadableLogLines(inProject projectID: UUID) -> Int {
        assistantLogUnreadable[projectID] ?? 0
    }

    /// A job entry as a row; other entries (note and item changes) aren't calls.
    private func logRow(for entry: AuditEntry, projectID: UUID) -> AssistantLogRow? {
        guard entry.action == .jobRan, let job = entry.job else { return nil }
        let (subject, retry) = describe(subject: job.subject, job: job.name, projectID: projectID)
        let result: AssistantLogRow.Result = job.succeeded
            ? .done(durationMS: job.durationMS, costUSD: job.costUSD)
            : .failed(message: job.failure ?? "It failed.", retry: retry)
        return AssistantLogRow(id: entry.id, at: entry.at, job: job.name, subject: subject, model: job.model, result: result)
    }

    /// A job's subject (an id) in words, and how to try it again: nil while
    /// the assistant is off, or when what it was about has gone.
    func describe(subject: String, job: String, projectID: UUID) -> (String, AssistantRetry?) {
        guard let id = UUID(uuidString: subject) else { return (subject, nil) }
        let on = isAssistantOn(inProject: projectID)
        if job == PromoteCheck.job {
            guard let note = assistantData[projectID]?.notes.first(where: { $0.id == id }) else { return ("A note that's gone", nil) }
            return (PlanTitle.from(note.text), on && note.itemID == nil ? .noteCheck(noteID: id) : nil)
        }
        if job == FollowUpJob.job {
            if let session = workspace.session(id) { return (session.name, on ? .followUp(sessionID: id) : nil) }
            return ("A session that's gone", nil)
        }
        if job == SkillDraftJob.job {
            guard let candidate = skillCandidate(id, inProject: projectID) else { return ("A lesson that's gone", nil) }
            return (PlanTitle.from(candidate.summary), on && candidate.state != .proposed ? .skillDraft(candidateID: id) : nil)
        }
        return (subject, nil)
    }

    /// Try Again on a failed call. False, with a toast saying why, when it
    /// can't run: the assistant is off, or what it was about has gone or
    /// changed. A note check never promotes the note: it only checks it.
    @discardableResult
    public func retry(_ retry: AssistantRetry, projectID: UUID) -> Bool {
        guard isAssistantOn(inProject: projectID) else {
            showToast("The assistant is off for this project")
            return false
        }
        switch retry {
        case .noteCheck(let noteID):
            guard let note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.itemID == nil else {
                showToast("That note has gone, or is in the plan now")
                return false
            }
            cancelHeldJob(key: .noteCheck(noteID))
            checkNote(note, projectID: projectID, askedFor: true)
            return true
        case .followUp(let sessionID):
            guard workspace.session(sessionID) != nil else {
                showToast("That session has gone")
                return false
            }
            if let failed = needsYouData(inProject: projectID).followUps.last(where: {
                guard $0.sessionID == sessionID, case .failed = $0.state else { return false }
                return true
            }) {
                retryFollowUp(failed.id, projectID: projectID)
            } else {
                reviewSession(sessionID)
            }
            return true
        case .skillDraft(let candidateID):
            guard skillCandidate(candidateID, inProject: projectID) != nil else {
                showToast("That lesson has gone")
                return false
            }
            guard startSkillDraft(candidateID, projectID: projectID, askedFor: true) else {
                if !draftingCandidates.contains(candidateID), !assistantSettings(forProject: projectID).dontSendTranscripts {
                    showToast("That lesson already has a draft waiting")
                }
                return false
            }
            return true
        }
    }
}
