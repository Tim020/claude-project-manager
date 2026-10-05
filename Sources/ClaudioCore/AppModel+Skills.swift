import Foundation

// Step 5 of the Project Assistant: skills. This part keeps `skills.json`
// (which sessions used which skill), reads the files each plan item's
// sessions touched (for chips), logs skill files that can't be used, and
// marks notes whose background check failed.

/// A background check of a note that failed, for its Check Failed marker.
public struct NoteCheckFailure: Equatable, Sendable {
    public var message: String
    public var at: Date
    /// "Haiku".
    public var model: String
}

extension AppModel {
    // MARK: - skills.json

    public func skillsData(inProject projectID: UUID) -> SkillsData {
        skillsData[projectID] ?? SkillsData()
    }

    /// At launch: each project's `skills.json`. One that can't be read is
    /// logged and left alone.
    func loadSkillsData() {
        for project in workspace.projects {
            do {
                let data = try assistantStore.loadSkillsData(projectID: project.id)
                savedSkillsData[project.id] = data
                if !data.isEmpty { skillsData[project.id] = data }
                if data.unreadableCount > 0 {
                    log.append(.error, "\(data.unreadableCount) of the assistant's skill entries for \(project.name) couldn't be read",
                               detail: "They're kept as they were.")
                }
            } catch {
                unreadableSkillsData.insert(project.id)
                log.append(.error, "Couldn't read the assistant's skills file for \(project.name)",
                           detail: AppModel.describe(error) + "\nIt's left as it is, and nothing about skills is saved until it can be read.")
            }
        }
    }

    /// Every change to `skills.json` comes through here: assigned only when
    /// it differs, and saved when it does. Nothing changes for a project
    /// whose file couldn't be read. False when it couldn't be saved.
    @discardableResult
    func updateSkillsData(_ projectID: UUID, _ body: (inout SkillsData) -> Void) -> Bool {
        guard !unreadableSkillsData.contains(projectID) else { return false }
        var data = skillsData(inProject: projectID)
        body(&data)
        guard data != skillsData(inProject: projectID) else { return true }
        skillsData[projectID] = data
        guard data != savedSkillsData[projectID] ?? SkillsData() else { return true }
        do {
            try assistantStore.saveSkillsData(data, projectID: projectID)
            savedSkillsData[projectID] = data
            return true
        } catch {
            log.append(.error, "Couldn't save the assistant's skills file for \(workspace.project(projectID)?.name ?? "a project")",
                       detail: AppModel.describe(error))
            return false
        }
    }

    // MARK: - Usage

    /// A hook event showing a session using one of its project's skills: an
    /// approved one, or one in the repository's `.claude/skills`. Others
    /// (Claude Code's own, the user's) aren't counted.
    func noteSkillUse(_ event: HookEvent, sessionID: UUID) {
        guard let name = SkillUseDetector.skill(in: event), let session = workspace.session(sessionID),
              isProjectSkill(name, projectID: session.projectID) else { return }
        let date = now()
        // Saved only for a new session, or a new day (see `recordUse`).
        updateSkillsData(session.projectID) { _ = $0.recordUse(of: name, by: sessionID, at: date) }
    }

    func isProjectSkill(_ name: String, projectID: UUID) -> Bool {
        if (approvedSkills[projectID] ?? []).contains(where: { $0.name == name }) { return true }
        guard let project = workspace.project(projectID) else { return false }
        return FileManager.default.fileExists(atPath: "\(project.path)/.claude/skills/\(name)/SKILL.md")
    }

    /// How many sessions used each skill, counting only sessions in a folder
    /// (nil: Unfiled), for chips: "how often it was used by sessions in that folder".
    public func skillUsage(inProject projectID: UUID, folderID: UUID?) -> [String: Int] {
        guard let project = workspace.project(projectID) else { return [:] }
        let filed = Set(project.folders.flatMap(\.sessionIDs))
        let inFolder: (UUID) -> Bool = { id in
            if let folderID { return project.folders.first { $0.id == folderID }?.sessionIDs.contains(id) ?? false }
            return !filed.contains(id) && self.workspace.session(id)?.projectID == projectID
        }
        var counts: [String: Int] = [:]
        for (name, usage) in skillsData(inProject: projectID).usage {
            let count = usage.sessions.filter(inFolder).count
            if count > 0 { counts[name] = count }
        }
        return counts
    }

    // MARK: - Skill files

    /// Logs skill files that can't be used, once each (until they change).
    func logSkillProblems(_ problems: [String], projectID: UUID) {
        let current = Set(problems)
        let new = current.subtracting(loggedSkillProblems[projectID] ?? [])
        loggedSkillProblems[projectID] = current
        guard !new.isEmpty else { return }
        let name = workspace.project(projectID)?.name ?? "a project"
        log.append(.error, "\(new.count) of the approved skill files for \(name) can't be used",
                   detail: new.sorted().joined(separator: "\n"))
    }

    // MARK: - Files a plan item's sessions touched

    /// Reads, off the main actor, the files an item's sessions edited, from
    /// their history files (cached by size and date). Called when the item
    /// or New Session from Plan opens, so chips don't depend on which
    /// sessions' Files Changed has loaded.
    public func refreshTouchedFiles(forItem item: PlanItem, inProject projectID: UUID) async {
        guard let project = workspace.project(projectID) else { return }
        var sessionIDs = Set(notes(forItem: item.id, inProject: projectID).compactMap(\.sessionID))
        if let sessionID = item.sessionID { sessionIDs.insert(sessionID) }
        let sessions = sessionIDs.compactMap { workspace.session($0) }
        let files = sessions.flatMap { session -> [URL] in
            guard let conversation = session.claudeSessionID else { return [] }
            return discovery.editLogFiles(projectPath: session.workingDirectory, claudeSessionID: conversation)
        }
        let cache = editLogCache, projectPath = project.path
        let touched = await Task.detached(priority: .utility) { () -> [String] in
            let edits = cache.summary(files: files).edits
            return Array(Set(edits.compactMap { SkillChips.relativePath($0.path, projectPath: projectPath) })).sorted()
        }.value
        if itemTouchedFiles[item.id] != touched { itemTouchedFiles[item.id] = touched }
    }

    // MARK: - Check Failed on a note

    /// A background check of the note failed: the note says so.
    func recordNoteCheckFailure(_ noteID: UUID, message: String, model: String) {
        noteCheckFailures[noteID] = NoteCheckFailure(message: message, at: now(), model: model)
    }

    func clearNoteCheckFailure(_ noteID: UUID) {
        if noteCheckFailures[noteID] != nil { noteCheckFailures[noteID] = nil }
    }

    /// The note's failed check, while it still has no plan item.
    public func noteCheckFailure(_ noteID: UUID, inProject projectID: UUID) -> NoteCheckFailure? {
        guard let failure = noteCheckFailures[noteID],
              let note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.itemID == nil else { return nil }
        return failure
    }

    /// Check Failed on a note: opens Job Failed for it, with Try Again.
    public func openNoteCheckFailure(_ noteID: UUID, projectID: UUID) {
        guard let failure = noteCheckFailure(noteID, inProject: projectID),
              let note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }) else { return }
        let row = AssistantLogRow(id: UUID(), at: failure.at, job: PromoteCheck.job, subject: PlanTitle.from(note.text),
                                  model: failure.model,
                                  result: .failed(message: failure.message,
                                                  retry: isAssistantOn(inProject: projectID) ? .noteCheck(noteID: noteID) : nil))
        assistantPanel = .jobFailed(projectID: projectID, row: row)
    }
}
