import Foundation

// Step 4a of the Project Assistant (design 9a): follow-ups and Needs You.
// Code decides when a session looks ready for a follow-up, from Claude
// Code's own signals rather than a timer: its turn ended normally, it isn't
// waiting on you, and Claude Code says its task is done or ready for review
// (or you stopped it, or closed its tab). Then, if something worth a look
// happened since the last follow-up, it's offered, and Claude is only asked
// if you say Follow Up. A new prompt in the session withdraws the offer.

extension AppModel {
    /// How often sessions are checked for being ready (cheap: no file is
    /// read unless one is, and its history has grown).
    public static let followUpCheckInterval: TimeInterval = 15
    /// Claude Code's task states that mean its task has finished.
    public static let readyTaskStates: Set<String> = ["done", "review_ready"]

    // MARK: - Reading Needs You

    public func needsYouData(inProject projectID: UUID) -> NeedsYouData {
        needsYou[projectID] ?? NeedsYouData()
    }

    /// The follow-up whose card shows under a session's terminal: the newest
    /// one that isn't deferred to Needs You.
    public func followUpCard(forSession sessionID: UUID) -> FollowUp? {
        guard let projectID = workspace.session(sessionID)?.projectID else { return nil }
        return needsYouData(inProject: projectID).followUps.last { $0.sessionID == sessionID && !$0.isDeferred }
    }

    public func followUp(_ id: UUID, inProject projectID: UUID) -> FollowUp? {
        needsYouData(inProject: projectID).followUps.first { $0.id == id }
    }

    /// The rail badge and the section's count: what's waiting for you.
    /// Jobs still running don't count. With the assistant off, only plan
    /// changes sessions suggested (`claudio suggest` told them you'd see them)
    /// and long-running background tasks, which aren't the assistant's.
    public func needsYouCount(inProject projectID: UUID, now: Date? = nil) -> Int {
        let data = needsYouData(inProject: projectID)
        let others = data.suggestions.count + longRunningSessions(inProject: projectID, now: now).count
        guard isAssistantOn(inProject: projectID) else { return others }
        return data.followUps.filter { $0.state != .working }.count + others
    }

    // MARK: - Finding sessions ready for a follow-up

    /// Looks for sessions that look ready and have something worth a
    /// follow-up, and offers one (every 15 s). An offer costs nothing: Claude
    /// is only asked when you accept it. Automatic mode only.
    public func checkFollowUps() async {
        // The same tick lets held-back work run (the daily limit at midnight, say).
        releaseHeldJobs()
        for session in workspace.sessions {
            guard isAssistantOn(inProject: session.projectID), assistantMode(ofProject: session.projectID) == .automatic,
                  isFollowUpCandidate(session) else { continue }
            await considerFollowUp(session.id)
        }
    }

    /// The cheap checks, before any file is read. A session looks ready when
    /// its last turn ended normally (a turn cut short by a usage limit or an
    /// API error doesn't), it isn't waiting on you, and Claude Code says its
    /// task is done or ready for review, or you stopped it or closed its tab.
    func isFollowUpCandidate(_ session: Session) -> Bool {
        guard !session.isArchived, session.hasConversation, session.claudeSessionID != nil,
              session.status == .completed, !session.lastTurnFailed,
              !isFollowUpPending(session.id) else { return false }
        return followUpDue.contains(session.id) || taskIsFinished(session)
    }

    /// Claude Code's own view of the session's task, from `claude agents`:
    /// done, or ready for review. Sessions without an agent (direct tabs)
    /// only look ready when stopped or their tab is closed.
    func taskIsFinished(_ session: Session) -> Bool {
        guard let state = session.agentID.flatMap({ agents[$0]?.state }) else { return false }
        return AppModel.readyTaskStates.contains(state)
    }

    private func isFollowUpRunning(_ sessionID: UUID) -> Bool {
        guard let projectID = workspace.session(sessionID)?.projectID else { return false }
        return needsYouData(inProject: projectID).followUps.contains { $0.sessionID == sessionID && $0.state == .working }
    }

    /// An offer, or a follow-up running, for the session.
    private func isFollowUpPending(_ sessionID: UUID) -> Bool {
        guard let projectID = workspace.session(sessionID)?.projectID else { return false }
        return needsYouData(inProject: projectID).followUps.contains {
            $0.sessionID == sessionID && ($0.state == .working || $0.state == .offered)
        }
    }

    /// The session's history file, and its size, for its current conversation.
    private func historyFile(of session: Session) -> (url: URL, conversationID: String, size: UInt64)? {
        guard let conversationID = session.claudeSessionID else { return nil }
        func size(_ url: URL) -> UInt64? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        }
        if let cached = followUpHistoryFiles[session.id], cached.conversationID == conversationID, let bytes = size(cached.url) {
            return (cached.url, conversationID, bytes)
        }
        guard followUpHistoryMissing[session.id] != conversationID, let project = workspace.project(session.projectID) else {
            return nil
        }
        // The newest, when a conversation has files in both the repository's
        // folder and a worktree's.
        guard let url = discovery.newestHistoryFile(projectPath: project.path, workingDirectory: session.workingDirectory,
                                                    claudeSessionID: conversationID),
              let bytes = size(url) else {
            followUpHistoryMissing[session.id] = conversationID
            return nil
        }
        followUpHistoryMissing[session.id] = nil
        followUpHistoryFiles[session.id] = (conversationID, url)
        return (url, conversationID, bytes)
    }

    /// Reads what's new in a ready session's history and, if it has
    /// substance, offers a follow-up. A session from before this build, seen
    /// for the first time, gets a mark at the end of its history instead.
    func considerFollowUp(_ sessionID: UUID) async {
        guard let session = workspace.session(sessionID), let file = historyFile(of: session) else { return }
        guard let mark = session.followUpMark else {
            setFollowUpMark(sessionID, FollowUpMark(conversationID: file.conversationID, offset: file.size))
            followUpDue.remove(sessionID)
            return
        }
        // After /clear, the new conversation is read from the top.
        let start = mark.conversationID == file.conversationID ? mark.offset : 0
        let checked = "\(file.conversationID):\(file.size)"
        // Unchanged since it was last looked at (or since Not Now): nothing new.
        guard file.size > start, followUpChecked[sessionID] != checked else {
            followUpDue.remove(sessionID)
            return
        }
        // Not Now (kept across launches): offered again only after a new
        // prompt. Other lines the history gains (a rename's title, Claude
        // Code's own bookkeeping, a stop) don't count.
        let declined = session.followUpDeclined.flatMap { $0.conversationID == file.conversationID ? $0.offset : nil }
        if let declined, file.size <= declined {
            followUpChecked[sessionID] = checked
            followUpDue.remove(sessionID)
            return
        }
        guard let project = workspace.project(session.projectID) else { return }
        let url = file.url, projectPath = project.path
        let read = await Task.detached(priority: .utility) { () -> Result<(digest: SessionDigest, end: UInt64, promptedSinceDecline: Bool), Error> in
            HistorySlice.read(url, from: start).map { read in
                let digest = SessionDigest.build(lines: read.lines, projectPath: projectPath)
                var prompted = true
                if let declined, case .success(let since) = HistorySlice.read(url, from: declined) {
                    prompted = !SessionDigest.build(lines: since.lines, projectPath: projectPath).prompts.isEmpty
                }
                return (digest, read.end, prompted)
            }
        }.value
        followUpDue.remove(sessionID)
        let slice: (digest: SessionDigest, end: UInt64, promptedSinceDecline: Bool)
        switch read {
        case .success(let value):
            slice = value
            followUpChecked[sessionID] = checked
        case .failure(let error):
            // Not marked as checked, so it's tried again on the next tick.
            log.append(.error, "Couldn't read the history of \(session.name) for a follow-up",
                       detail: "\(file.url.path)\n\(AppModel.describe(error))")
            return
        }
        // Nothing worth a look yet: the mark stays, so prompts add up
        // ("3 or more since the last follow-up").
        guard slice.promptedSinceDecline, !slice.digest.prompts.isEmpty, slice.digest.hasSubstance,
              let current = workspace.session(sessionID), current.status == .completed, !current.lastTurnFailed,
              !isFollowUpPending(sessionID)
        else { return }
        offerFollowUp(sessionID, digest: slice.digest,
                      mark: FollowUpMark(conversationID: file.conversationID, offset: slice.end))
    }

    /// "Shell Height looks done. Follow up?": no call until you accept.
    func offerFollowUp(_ sessionID: UUID, digest: SessionDigest, mark: FollowUpMark) {
        guard let session = workspace.session(sessionID) else { return }
        let offer = FollowUp(sessionID: sessionID, sessionName: session.name, state: .offered, createdAt: now(), askedFor: false)
        dropStaleFailures(forSession: sessionID, projectID: session.projectID)
        updateNeedsYou(session.projectID) { data in
            data.followUps.removeAll { $0.sessionID == sessionID && $0.state == .offered }
            data.followUps.append(offer)
        }
        pendingDigests[offer.id] = (digest, mark)
    }

    /// A session's failed follow-up that's still on its card: a new offer or
    /// follow-up covers the same work, so it goes. One deferred to Needs You
    /// stays until you deal with it.
    private func dropStaleFailures(forSession sessionID: UUID, projectID: UUID, except keep: UUID? = nil) {
        let stale = needsYouData(inProject: projectID).followUps.filter {
            guard $0.sessionID == sessionID, !$0.isDeferred, $0.id != keep, case .failed = $0.state else { return false }
            return true
        }.map(\.id)
        guard !stale.isEmpty else { return }
        for id in stale { pendingDigests[id] = nil }
        updateNeedsYou(projectID) { data in data.followUps.removeAll { stale.contains($0.id) } }
    }

    /// Follow Up on an offer: the call runs now, as something you started
    /// (not background work: no usage gate, no daily limit).
    public func acceptFollowUpOffer(_ id: UUID, projectID: UUID) {
        guard let offer = followUp(id, inProject: projectID), offer.state == .offered else { return }
        guard let (digest, mark) = pendingDigests[id] else {
            reviewSession(offer.sessionID, replacing: id)
            return
        }
        startFollowUp(offer.sessionID, digest: digest, mark: mark, askedFor: true, replacing: id)
    }

    /// Not Now: the offer goes, and comes back only after the session does
    /// more and looks ready again. Where it had got to is kept with the
    /// session, so a relaunch doesn't offer it again.
    public func declineFollowUpOffer(_ id: UUID, projectID: UUID) {
        guard let offer = followUp(id, inProject: projectID) else { return }
        if let (_, mark) = pendingDigests[id] { setFollowUpDeclined(offer.sessionID, mark) }
        closeFollowUp(id, projectID: projectID)
    }

    /// A new prompt in the session: it's carrying on, so an offer made for
    /// where it had got to no longer applies.
    func withdrawFollowUpOffer(forSession sessionID: UUID) {
        guard let projectID = workspace.session(sessionID)?.projectID else { return }
        let offers = needsYouData(inProject: projectID).followUps.filter { $0.sessionID == sessionID && $0.state == .offered }
        guard !offers.isEmpty else { return }
        for offer in offers { pendingDigests[offer.id] = nil }
        updateNeedsYou(projectID) { data in data.followUps.removeAll { $0.sessionID == sessionID && $0.state == .offered } }
    }

    // MARK: - Review This Session

    /// Review This Session (the session's ⋯ menu): a follow-up now, whatever
    /// the usage. It reads what's new since the last follow-up, or the whole
    /// conversation when nothing is. With the assistant off, it says so.
    /// `replacing`: the card it takes over (an offer, or a failure after a
    /// relaunch), which stays if nothing can be reviewed.
    public func reviewSession(_ sessionID: UUID, replacing followUpID: UUID? = nil) {
        guard let session = workspace.session(sessionID) else { return }
        guard isAssistantOn(inProject: session.projectID) else {
            showToast("The assistant is off for this project")
            return
        }
        // A second click while the first is still reading the history.
        guard !isFollowUpRunning(sessionID), !reviewsStarting.contains(sessionID) else { return }
        guard let file = historyFile(of: session), let project = workspace.project(session.projectID) else {
            showToast("This session has nothing to review yet")
            return
        }
        let mark = session.followUpMark
        let start = mark?.conversationID == file.conversationID ? mark?.offset ?? 0 : 0
        let url = file.url, projectPath = project.path
        reviewsStarting.insert(sessionID)
        Task { @MainActor [weak self] in
            let read = await Task.detached(priority: .userInitiated) { () -> Result<(digest: SessionDigest, end: UInt64), Error> in
                HistorySlice.read(url, from: start).flatMap { read in
                    let digest = SessionDigest.build(lines: read.lines, projectPath: projectPath)
                    guard digest.prompts.isEmpty, start > 0 else { return .success((digest, read.end)) }
                    // Nothing new since the last follow-up: review the whole conversation.
                    return HistorySlice.read(url, from: 0).map { whole in
                        (SessionDigest.build(lines: whole.lines, projectPath: projectPath), whole.end)
                    }
                }
            }.value
            guard let self else { return }
            self.reviewsStarting.remove(sessionID)
            switch read {
            case .failure(let error):
                self.log.append(.error, "Couldn't read the history of \(session.name) to review it",
                                detail: "\(url.path)\n\(AppModel.describe(error))")
                self.showToast("Couldn't read this session's history. See the Activity Log.")
            case .success(let slice) where slice.digest.prompts.isEmpty:
                self.showToast("This session has nothing to review yet")
            case .success(let slice):
                self.startFollowUp(sessionID, digest: slice.digest,
                                   mark: FollowUpMark(conversationID: file.conversationID, offset: slice.end), askedFor: true,
                                   replacing: followUpID)
            }
        }
    }

    // MARK: - Running a follow-up

    /// Shows the working card and queues the call. One per session: a newer
    /// request replaces one still waiting.
    func startFollowUp(_ sessionID: UUID, digest: SessionDigest, mark: FollowUpMark, askedFor: Bool,
                       replacing followUpID: UUID? = nil) {
        guard let session = workspace.session(sessionID) else { return }
        let projectID = session.projectID
        var followUp = FollowUp(sessionID: sessionID, sessionName: session.name, state: .working, createdAt: now(),
                                askedFor: askedFor)
        followUp.model = AssistantModels.displayName(assistantSettings(forProject: projectID).deepModel.rawValue)
        if let followUpID { followUp.id = followUpID }
        dropStaleFailures(forSession: sessionID, projectID: projectID, except: followUpID)
        updateNeedsYou(projectID) { data in
            data.followUps.removeAll {
                $0.id == followUp.id || ($0.sessionID == sessionID && ($0.state == .working || $0.state == .offered))
            }
            data.followUps.append(followUp)
        }
        let item = items(inProject: projectID).first { $0.sessionID == sessionID && $0.status != .done }
        let request = FollowUpJob.request(digest: digest, mark: mark, sessionName: session.name,
                                          items: items(inProject: projectID), sessionItem: item,
                                          sessionNotes: notes(inProject: projectID).filter { $0.sessionID == sessionID },
                                          memoryIndex: memoryIndex(forProject: projectID),
                                          withTranscripts: !assistantSettings(forProject: projectID).dontSendTranscripts,
                                          model: assistantSettings(forProject: projectID).deepModel)
        let id = followUp.id
        runAssistantJob(request.call, projectID: projectID, subject: sessionID.uuidString, key: "followup:\(sessionID)",
                        isBackground: !askedFor) {
            [weak self] result in
            self?.finishFollowUp(id, sessionID: sessionID, projectID: projectID, request: request, digest: digest,
                                 result: result)
        }
    }

    private func finishFollowUp(_ id: UUID, sessionID: UUID, projectID: UUID, request: FollowUpJob.Request,
                                digest: SessionDigest, result: Result<AssistantReply, AssistantFailure>) {
        // Closed, or replaced, while it ran.
        guard followUp(id, inProject: projectID) != nil else { return }
        switch result {
        case .failure(let failure):
            // The mark stays, so nothing it would have read is skipped.
            updateFollowUp(id, projectID: projectID) { $0.state = .failed(failure.message) }
            pendingDigests[id] = (digest, request.mark)
        case .success(let reply):
            let (texts, changes) = FollowUpJob.result(from: reply.output, refs: request.refs,
                                                      items: items(inProject: projectID))
            var kept: [FollowUpNote] = []
            var unsaved: [String] = []
            for text in texts {
                if let note = addNote(text, author: .assistant, projectID: projectID, sessionID: sessionID,
                                      cause: "followup:\(id.uuidString.lowercased())", reportFailures: false) {
                    kept.append(FollowUpNote(text: text, noteID: note.id))
                } else {
                    // Not shown as an unticked row (that means you removed it): logged with its text.
                    unsaved.append(text)
                }
            }
            if !unsaved.isEmpty {
                log.append(.error, "Couldn't save \(unsaved.count) of a follow-up's notes", detail: unsaved.joined(separator: "\n\n"))
            }
            setFollowUpMark(sessionID, request.mark)
            pendingDigests[id] = nil
            updateFollowUp(id, projectID: projectID) { followUp in
                followUp.state = .ready
                followUp.notes = kept
                followUp.planChanges = changes
            }
            let name = workspace.session(sessionID)?.name ?? "a session"
            log.append(.info, "Assistant: followed up \(name): \(kept.count) note\(kept.count == 1 ? "" : "s"), "
                       + "\(changes.count) plan change\(changes.count == 1 ? "" : "s")")
        }
    }

    /// The project's auto-memory index (`MEMORY.md`), so the follow-up
    /// doesn't suggest a note memory already has.
    func memoryIndex(forProject projectID: UUID) -> String? {
        guard let project = workspace.project(projectID) else { return nil }
        let url = discovery.projectDirectory(for: project.path).appendingPathComponent("memory/MEMORY.md")
        return (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(4000)) }
    }

    // MARK: - The card's actions

    /// Try Again on a failed follow-up: the same digest, asked again.
    public func retryFollowUp(_ id: UUID, projectID: UUID) {
        guard let followUp = followUp(id, inProject: projectID), case .failed = followUp.state else { return }
        guard let (digest, mark) = pendingDigests[id] else {
            // After a relaunch the digest is gone: read the session afresh.
            // The failed card stays until the new follow-up takes its place.
            reviewSession(followUp.sessionID, replacing: id)
            return
        }
        startFollowUp(followUp.sessionID, digest: digest, mark: mark, askedFor: followUp.askedFor, replacing: id)
    }

    /// A note row's tick: unticking removes the note, ticking saves it again.
    public func toggleFollowUpNote(_ noteRowID: UUID, in followUpID: UUID, projectID: UUID) {
        guard let followUp = followUp(followUpID, inProject: projectID),
              let row = followUp.notes.first(where: { $0.id == noteRowID }) else { return }
        var noteID: UUID?
        if let existing = row.noteID {
            if assistantData[projectID]?.notes.contains(where: { $0.id == existing }) == true {
                undoNote(existing, projectID: projectID)
            }
            // Only unticked once it's really gone (a failed save leaves it).
            guard assistantData[projectID]?.notes.contains(where: { $0.id == existing }) != true else { return }
            noteID = nil
        } else {
            noteID = addNote(row.text, author: .assistant, projectID: projectID, sessionID: followUp.sessionID,
                             cause: "followup:\(followUpID.uuidString.lowercased())")?.id
            if noteID == nil { return }
        }
        updateFollowUp(followUpID, projectID: projectID) { followUp in
            if let index = followUp.notes.firstIndex(where: { $0.id == noteRowID }) { followUp.notes[index].noteID = noteID }
        }
    }

    public func togglePlanChange(_ changeID: UUID, in followUpID: UUID, projectID: UUID) {
        updateFollowUp(followUpID, projectID: projectID) { followUp in
            if let index = followUp.planChanges.firstIndex(where: { $0.id == changeID }) {
                followUp.planChanges[index].isSelected.toggle()
            }
        }
    }

    /// Add n to Plan: applies the ticked plan changes and closes the card.
    /// Each is checked again: an item that has gone, or is done, is skipped.
    /// A change that can't be saved stays on the card, to try again.
    public func addFollowUpPlanChanges(_ followUpID: UUID, projectID: UUID) {
        guard let followUp = followUp(followUpID, inProject: projectID) else { return }
        var added = 0
        var failed = Set<UUID>()
        for proposal in followUp.planChanges where proposal.isSelected && proposal.isValid {
            switch proposal.kind {
            case .add:
                let item = PlanItem(title: proposal.title, status: proposal.status, createdAt: now())
                let entry = AuditEntry(at: now(), actor: .user, action: .itemAdded, afterItem: item,
                                       cause: "followup:\(followUpID.uuidString.lowercased())")
                if change(projectID: projectID, recording: entry, { $0.items.append(item) }) { added += 1 } else { failed.insert(proposal.id) }
            case .done, .move:
                guard let itemID = proposal.itemID, let item = item(itemID, inProject: projectID),
                      item.status != .done, item.status != proposal.status else { continue }
                if setStatus(proposal.status, ofItem: itemID, projectID: projectID) { added += 1 } else { failed.insert(proposal.id) }
            }
        }
        guard failed.isEmpty else {
            updateFollowUp(followUpID, projectID: projectID) { $0.planChanges.removeAll { $0.isSelected && !failed.contains($0.id) } }
            showToast("Added \(added) of \(added + failed.count). The rest couldn't be saved.")
            return
        }
        closeFollowUp(followUpID, projectID: projectID)
        if added > 0 { showToast(added == 1 ? "Added 1 change to the plan" : "Added \(added) changes to the plan") }
    }

    /// Later, or ✕: the card leaves the session and waits in Needs You as
    /// "<session> finished".
    public func deferFollowUp(_ id: UUID, projectID: UUID) {
        updateFollowUp(id, projectID: projectID) { $0.isDeferred = true }
    }

    /// Close (or nothing to keep): it's done with. Saved notes stay.
    public func closeFollowUp(_ id: UUID, projectID: UUID) {
        pendingDigests[id] = nil
        updateNeedsYou(projectID) { $0.followUps.removeAll { $0.id == id } }
    }

    // MARK: - Suggestions from sessions (`claudio suggest`)

    func addSessionSuggestion(_ text: String, session: Session?, projectID: UUID) {
        let suggestion = SessionSuggestion(sessionID: session?.id, sessionName: session?.name,
                                           text: String(text.prefix(AppModel.sessionNoteLimit)), createdAt: now())
        updateNeedsYou(projectID) { $0.suggestions.append(suggestion) }
        log.append(.info, "\(session?.name ?? "A session") suggested a plan change")
    }

    /// Add to Plan on a session's suggestion: a new item titled from it.
    public func acceptSessionSuggestion(_ id: UUID, projectID: UUID, status: PlanStatus = .planned) {
        guard let suggestion = needsYouData(inProject: projectID).suggestions.first(where: { $0.id == id }) else { return }
        let item = PlanItem(title: PlanTitle.from(suggestion.text), status: status, createdAt: now())
        let entry = AuditEntry(at: now(), actor: .user, action: .itemAdded, afterItem: item,
                               cause: suggestion.sessionID?.uuidString.lowercased() ?? "session")
        guard change(projectID: projectID, recording: entry, { $0.items.append(item) }) else { return }
        dismissSessionSuggestion(id, projectID: projectID)
        showToast(status == .idea ? "Added to Plan as an Idea" : "Added to Plan as \(status.label)")
    }

    public func dismissSessionSuggestion(_ id: UUID, projectID: UUID) {
        updateNeedsYou(projectID) { $0.suggestions.removeAll { $0.id == id } }
    }

    // MARK: - Keeping Needs You

    func updateFollowUp(_ id: UUID, projectID: UUID, _ body: (inout FollowUp) -> Void) {
        updateNeedsYou(projectID) { data in
            if let index = data.followUps.firstIndex(where: { $0.id == id }) { body(&data.followUps[index]) }
        }
    }

    /// Every change to Needs You comes through here: it's assigned only
    /// when it differs, and saved (without working follow-ups) when that does.
    func updateNeedsYou(_ projectID: UUID, _ body: (inout NeedsYouData) -> Void) {
        var data = needsYouData(inProject: projectID)
        body(&data)
        guard data != needsYouData(inProject: projectID) else { return }
        needsYou[projectID] = data
        let saved = data.saved
        guard saved != savedNeedsYou[projectID] ?? NeedsYouData(), !isAssistantDataUnreadable(projectID) else { return }
        do {
            try assistantStore.saveNeedsYou(saved, projectID: projectID)
            savedNeedsYou[projectID] = saved
        } catch {
            log.append(.error, "Couldn't save Needs You for \(workspace.project(projectID)?.name ?? "a project")",
                       detail: AppModel.describe(error))
        }
    }

    /// At launch: each project's Needs You, with notes that have gone
    /// since marked as not kept.
    func loadNeedsYou() {
        for project in workspace.projects where !isAssistantDataUnreadable(project.id) {
            var data = assistantStore.loadNeedsYou(projectID: project.id)
            savedNeedsYou[project.id] = data
            if data.unreadableCount > 0 {
                log.append(.error, "\(data.unreadableCount) of Needs You's entries for \(project.name) couldn't be read",
                           detail: "They're kept as they were.")
            }
            let notes = Set(assistantData[project.id]?.notes.map(\.id) ?? [])
            for index in data.followUps.indices {
                for row in data.followUps[index].notes.indices
                where data.followUps[index].notes[row].noteID.map({ !notes.contains($0) }) ?? false {
                    data.followUps[index].notes[row].noteID = nil
                }
            }
            if !data.isEmpty { needsYou[project.id] = data }
        }
    }
}
