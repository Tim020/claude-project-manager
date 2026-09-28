import Foundation

// The Project Assistant (design 9a): a left-rail tool that follows the
// selected session's project. Step 1 of its build is notes: captured with
// ⌘⇧N, saved straight away, and listed newest first.

extension AppModel {
    /// Reads every project's assistant data at launch. A project whose file
    /// can't be read keeps its notes on disk: it isn't written to until it
    /// reads again, so nothing is overwritten.
    func loadAssistantData() {
        var notes: [UUID: [ProjectNote]] = [:]
        for project in state.workspace.projects {
            do {
                notes[project.id] = try assistantStore.load(projectID: project.id).notes
            } catch {
                unreadableAssistantProjects.insert(project.id)
                log.append(.error, "Couldn't read the assistant's notes for \(project.name)", detail: AppModel.describe(error))
            }
        }
        if notes != assistantNotes { assistantNotes = notes }
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
        (assistantNotes[projectID] ?? []).reversed()
    }

    /// "You · linked to Shell Follow Up · 3h", with the session's current
    /// name when it still exists.
    public func metaLine(for note: ProjectNote) -> String {
        let name = note.sessionID.flatMap { workspace.session($0)?.name } ?? note.sessionName
        return NoteMeta.line(for: note, sessionName: name, now: now())
    }

    // MARK: - Capture (⌘⇧N)

    /// New Note: opens the Assistant with the capture box, linked to the
    /// focused session when it's in the Assistant's project.
    public func beginNoteCapture() {
        guard let projectID = assistantProjectID else { return }
        var settings = state.settings
        settings.toolWindows.left = .assistant
        settings.toolWindows.isLeftOpen = true
        if settings != state.settings { updateSettings(settings) }
        updateMenuFlags()
        let session = selectedSession.flatMap { $0.projectID == projectID ? $0.id : nil }
        // Pressed again while open, it keeps what's been typed.
        if noteCapture?.projectID == projectID && noteCapture?.sessionID == session { return }
        noteCapture = NoteCapture(projectID: projectID, sessionID: session)
    }

    public func updateNoteCapture(_ text: String) {
        guard var capture = noteCapture, capture.text != text else { return }
        capture.text = text
        noteCapture = capture
    }

    public func cancelNoteCapture() {
        noteCapture = nil
    }

    /// Save Note: nothing happens while the text is blank.
    @discardableResult
    public func saveNoteCapture() -> ProjectNote? {
        guard let capture = noteCapture else { return nil }
        guard let note = addNote(capture.text, author: .user, projectID: capture.projectID, sessionID: capture.sessionID) else {
            return nil
        }
        noteCapture = nil
        showToast("Saved to Notes")
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
    func addNote(_ text: String, author: NoteAuthor, projectID: UUID, sessionID: UUID?, cause: String = "ui") -> ProjectNote? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, workspace.project(projectID) != nil else { return nil }
        let note = ProjectNote(text: text, author: author, sessionID: sessionID,
                               sessionName: sessionID.flatMap { workspace.session($0)?.name }, createdAt: now())
        guard change(projectID: projectID, { $0.append(note) }) else { return nil }
        audit(AuditEntry(at: now(), actor: author, action: .noteAdded, after: note, cause: cause), projectID: projectID)
        log.append(.info, "Saved a note in \(workspace.project(projectID)?.name ?? "a project")")
        return note
    }

    /// Undo on a note the assistant or a session wrote.
    public func undoNote(_ noteID: UUID, projectID: UUID) {
        guard let note = assistantNotes[projectID]?.first(where: { $0.id == noteID }), note.canUndo else { return }
        remove(note, projectID: projectID, action: .noteUndone)
    }

    /// Delete Note, from a note's context menu: any author's.
    public func deleteNote(_ noteID: UUID, projectID: UUID) {
        guard let note = assistantNotes[projectID]?.first(where: { $0.id == noteID }) else { return }
        remove(note, projectID: projectID, action: .noteDeleted)
    }

    private func remove(_ note: ProjectNote, projectID: UUID, action: AuditEntry.Action) {
        guard change(projectID: projectID, { $0.removeAll { $0.id == note.id } }) else { return }
        audit(AuditEntry(at: now(), actor: .user, action: action, before: note, cause: "ui"), projectID: projectID)
    }

    /// Applies a change to a project's notes and saves it. False (and an
    /// error shown) when it can't be saved, leaving the notes as they were.
    private func change(projectID: UUID, _ body: (inout [ProjectNote]) -> Void) -> Bool {
        guard !unreadableAssistantProjects.contains(projectID) else {
            report("The assistant's notes for this project couldn't be read, so they can't be changed. See the Activity Log.")
            return false
        }
        var notes = assistantNotes[projectID] ?? []
        body(&notes)
        do {
            try assistantStore.save(AssistantData(notes: notes), projectID: projectID)
        } catch {
            report("Couldn't save the note: \(AppModel.describe(error))")
            return false
        }
        assistantNotes[projectID] = notes
        return true
    }

    private func audit(_ entry: AuditEntry, projectID: UUID) {
        do {
            try assistantStore.appendAudit(entry, projectID: projectID)
        } catch {
            log.append(.error, "Couldn't record an assistant change", detail: AppModel.describe(error))
        }
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
