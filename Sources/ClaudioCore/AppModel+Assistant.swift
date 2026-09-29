import Foundation

// The Project Assistant (design 9a): a left-rail tool that follows the
// selected session's project. Step 1 of its build is notes: captured with
// ⌘⇧N, saved straight away, and listed newest first.

extension AppModel {
    /// Reads every project's assistant data at launch. A project whose file
    /// can't be read keeps its data on disk: it isn't written to again until
    /// a later launch reads it, so nothing is overwritten.
    func loadAssistantData() {
        var loaded: [UUID: AssistantData] = [:]
        var unreadable = Set<UUID>()
        for project in state.workspace.projects {
            do {
                let data = try assistantStore.load(projectID: project.id)
                loaded[project.id] = data
                if !data.unreadableReasons.isEmpty {
                    let place = assistantStore.location(projectID: project.id).map { "\($0)\n" } ?? ""
                    log.append(.error, "Some of the assistant's entries for \(project.name) couldn't be read",
                               detail: place + data.unreadableReasons.joined(separator: "\n") + "\nThey're kept as they were.")
                }
            } catch {
                unreadable.insert(project.id)
                let place = assistantStore.location(projectID: project.id).map { "\($0): " } ?? ""
                log.append(.error, "Couldn't read the assistant's notes for \(project.name)",
                           detail: place + AppModel.describe(error))
            }
        }
        if loaded != assistantData { assistantData = loaded }
        if unreadable != unreadableAssistantProjects { unreadableAssistantProjects = unreadable }
        // The suggestions that were showing, where they still apply; any
        // that don't are dropped from the file too.
        for project in state.workspace.projects where !unreadable.contains(project.id) {
            restoreNoteSuggestions(projectID: project.id)
        }
        persistNoteSuggestions()
    }

    /// Whether a project's assistant file couldn't be read at launch: its
    /// notes can't be shown or changed until it can.
    public func isAssistantDataUnreadable(_ projectID: UUID) -> Bool {
        unreadableAssistantProjects.contains(projectID)
    }

    /// The project the Assistant shows: the selected session's (or overview
    /// tab's), else the first project.
    public var assistantProjectID: UUID? {
        if let session = selectedSession { return session.projectID }
        if let overview = selectedOverview, let project = workspace.projectID(of: overview) { return project }
        return workspace.projects.first?.id
    }

    /// A project's notes, newest first.
    public func notes(inProject projectID: UUID) -> [ProjectNote] {
        (assistantData[projectID]?.notes ?? []).reversed()
    }

    /// "You · linked to Shell Follow Up · 3h", with the session's current
    /// name when it still exists.
    public func metaLine(for note: ProjectNote) -> String {
        let name = note.sessionID.flatMap { workspace.session($0)?.name } ?? note.sessionName
        return NoteMeta.line(for: note, sessionName: name, now: now())
    }

    // MARK: - Capture (⌘⇧N)

    /// New Note: opens the Assistant with the capture box, linked to the
    /// focused session when it's in the Assistant's project. For a project
    /// whose notes couldn't be read, it opens the Assistant, which says so.
    public func beginNoteCapture() {
        guard let projectID = assistantProjectID else { return }
        var settings = state.settings
        settings.toolWindows.left = .assistant
        settings.toolWindows.isLeftOpen = true
        if settings != state.settings { updateSettings(settings) }
        updateMenuFlags()
        guard !isAssistantDataUnreadable(projectID) else { return }
        // The note lands in the Notes list, as the design shows.
        closePlanItem()
        setAssistantListMode(.notes)
        // Even when the box is already open, it takes the keyboard back.
        noteCaptureFocusRequest &+= 1
        // Pressed again with the link removed, it stays unlinked: the unlink
        // was a choice about this note, not the session in front of you.
        if let current = noteCapture, current.projectID == projectID, current.isLinkRemoved { return }
        let capture = NoteCapture(projectID: projectID, sessionID: selectedSession.flatMap { $0.projectID == projectID ? $0.id : nil })
        // Pressed again for the same place, it keeps what's been typed.
        guard capture != noteCapture else { return }
        noteCapture = capture
        if !noteDraft.isEmpty { noteDraft = "" }
    }

    /// The × on "Linked to Shell Follow Up": this note isn't about that
    /// session (a new idea, say), so it's saved without a link.
    public func unlinkNoteCapture() {
        guard var capture = noteCapture, capture.sessionID != nil else { return }
        capture.sessionID = nil
        capture.isLinkRemoved = true
        noteCapture = capture
    }

    /// Whether the capture box is on screen: it's open, the Assistant is
    /// showing, and it's showing the capture's project. While it is, session
    /// terminals leave the keyboard alone.
    public var isNoteCaptureShowing: Bool {
        guard let capture = noteCapture else { return false }
        return toolWindows.visibleLeft == .assistant && capture.projectID == assistantProjectID
    }

    public func updateNoteDraft(_ text: String) {
        if noteDraft != text { noteDraft = text }
    }

    public func cancelNoteCapture() {
        noteCapture = nil
        if !noteDraft.isEmpty { noteDraft = "" }
    }

    /// Save Note: nothing happens while the text is blank.
    @discardableResult
    public func saveNoteCapture() -> ProjectNote? {
        guard let capture = noteCapture,
              let note = addNote(noteDraft, author: .user, projectID: capture.projectID, sessionID: capture.sessionID)
        else { return nil }
        cancelNoteCapture()
        showToast("Saved to Notes")
        checkCapturedNote(note, projectID: capture.projectID)
        return note
    }

    /// The capture box's "Linked to Shell Follow Up".
    public var noteCaptureLinkText: String {
        guard let id = noteCapture?.sessionID, let session = workspace.session(id) else { return "Not linked to a session" }
        return "Linked to \(session.name)"
    }

    // MARK: - Notes

    /// Adds a note by any author, saved straight away.
    @discardableResult
    func addNote(_ text: String, author: NoteAuthor, projectID: UUID, sessionID: UUID?, itemID: UUID? = nil,
                 cause: String = "ui") -> ProjectNote? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, workspace.project(projectID) != nil else { return nil }
        let note = ProjectNote(text: text, author: author, sessionID: sessionID,
                               sessionName: sessionID.flatMap { workspace.session($0)?.name }, createdAt: now(), itemID: itemID)
        let entry = AuditEntry(at: now(), actor: author, action: .noteAdded, after: note, cause: cause)
        guard change(projectID: projectID, recording: entry, { $0.notes.append(note) }) else { return nil }
        log.append(.info, "Saved a note in \(workspace.project(projectID)?.name ?? "a project")")
        return note
    }

    /// Undo on a note the assistant or a session wrote.
    public func undoNote(_ noteID: UUID, projectID: UUID) {
        guard let note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.canUndo else { return }
        remove(note, projectID: projectID, action: .noteUndone)
    }

    /// Delete Note, from a note's context menu: any author's. Its plan item,
    /// if it has one, keeps going without it.
    public func deleteNote(_ noteID: UUID, projectID: UUID) {
        guard let note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }) else { return }
        remove(note, projectID: projectID, action: .noteDeleted)
    }

    private func remove(_ note: ProjectNote, projectID: UUID, action: AuditEntry.Action) {
        let entry = AuditEntry(at: now(), actor: .user, action: action, before: note, cause: "ui")
        guard change(projectID: projectID, recording: entry, { $0.notes.removeAll { $0.id == note.id } }) else { return }
        clearNoteSuggestion(note.id)
    }

    /// Applies a change to a project's data. The audit entry is written
    /// first, so every change that lands can be reversed; then the whole of
    /// the data is saved (so whatever else it holds is kept). False, with an
    /// error shown, when either fails, leaving the data as it was. A failed
    /// save leaves its audit entry behind, so readers of the log check an
    /// entry against the data before acting on it.
    func change(projectID: UUID, recording entry: AuditEntry, _ body: (inout AssistantData) -> Void) -> Bool {
        change(projectID: projectID, recording: [entry], body)
    }

    /// A change made of several steps (Promote adds an item and attaches a
    /// note): one audit entry each, all written before the save.
    func change(projectID: UUID, recording entries: [AuditEntry], _ body: (inout AssistantData) -> Void) -> Bool {
        guard !isAssistantDataUnreadable(projectID) else {
            report("The assistant's notes for this project couldn't be read, so they can't be changed. See the Activity Log.")
            return false
        }
        var data = assistantData[projectID] ?? AssistantData()
        body(&data)
        do {
            for entry in entries { try assistantStore.appendAudit(entry, projectID: projectID) }
        } catch {
            report("Couldn't record the change, so it wasn't made: \(AppModel.describe(error))")
            return false
        }
        do {
            try assistantStore.save(data, projectID: projectID)
        } catch {
            report("Couldn't save the change: \(AppModel.describe(error))")
            return false
        }
        assistantData[projectID] = data
        writePlanSnapshot(projectID: projectID)
        return true
    }

    // MARK: - Toast

    public func showToast(_ text: String) {
        toast = Toast(text)
    }

    /// Clears the toast, unless a newer one has replaced it.
    public func clearToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }
}
