import Foundation

// Step 3 of the Project Assistant (design 9a): sessions and the assistant.
// New sessions get Claudio's plugin and the project's skills; a plan item
// can start a session with an opening prompt; sessions write notes back
// through the inbox.

/// What the New Session from Plan sheet starts from.
public struct PlanSessionDraft: Equatable, Sendable {
    public var name: String
    /// The session's folder (nil: Unfiled, the default).
    public var folderID: UUID?
    public var role: SessionRole
    /// The opening prompt without its skills line.
    public var promptBody: String
    /// The skills picked for it, best first (the chips).
    public var skills: [String]
}

extension AppModel {
    // MARK: - Files sessions use

    /// At launch: Claudio's plugin, every project's skills folder, the
    /// project index, each plan's snapshot and the approved skills; then
    /// any notes sessions wrote while Claudio was closed.
    func prepareAssistantFiles() {
        do {
            assistantPluginPath = try assistantStore.installPlugin()?.path
        } catch {
            // A failed update leaves the old copy in place, which still works.
            assistantPluginPath = assistantStore.existingPlugin()?.path
            log.append(.error, "Couldn't set up Claudio's plugin for sessions",
                       detail: AppModel.describe(error) + (assistantPluginPath == nil
                           ? "\nNew sessions start without it, so they can't write notes."
                           : "\nNew sessions get the copy already there."))
        }
        for project in workspace.projects {
            prepareSkillsRoot(projectID: project.id)
            writePlanSnapshot(projectID: project.id)
            refreshApprovedSkills(projectID: project.id)
        }
        writeAssistantIndex()
        pollAssistantInbox()
    }

    /// The project's skills root, created if it's missing. Nil (logged) when
    /// it can't be made, so no session is launched with a path that isn't there.
    @discardableResult
    func prepareSkillsRoot(projectID: UUID) -> URL? {
        do {
            return try assistantStore.skillsRoot(projectID: projectID)
        } catch {
            log.append(.error, "Couldn't make the skills folder for \(workspace.project(projectID)?.name ?? "a project")",
                       detail: AppModel.describe(error))
            return nil
        }
    }

    /// The assistant's flags for a session's launch: a new session, a direct
    /// `--resume`, or a background resume that isn't continuing an agent (never
    /// one that is: that would copy it). Given whatever the project's mode:
    /// Off means no Claude calls, not no notes.
    func assistantLaunch(forProject projectID: UUID) -> AssistantLaunch? {
        let plugin = assistantPluginPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let launch = AssistantLaunch(pluginDirectory: plugin, skillsRoot: prepareSkillsRoot(projectID: projectID)?.path)
        return launch.isEmpty ? nil : launch
    }

    /// `index.tsv`, whenever the projects change (checked on every save,
    /// and only written when its text changes).
    func writeAssistantIndex() {
        // A project whose notes can't be read is left out, so `claudio`
        // refuses there rather than write notes that can't be saved.
        let text = AssistantIndex.text(projects: workspace.projects.filter { !isAssistantDataUnreadable($0.id) })
        guard text != writtenAssistantIndex else { return }
        do {
            try assistantStore.writeIndex(text)
            writtenAssistantIndex = text
        } catch {
            log.append(.error, "Couldn't write the assistant's project index", detail: AppModel.describe(error))
        }
    }

    /// `plan.md`, after every change to a project's plan or notes.
    func writePlanSnapshot(projectID: UUID) {
        guard let project = workspace.project(projectID), !isAssistantDataUnreadable(projectID) else { return }
        let text = PlanSnapshot.text(projectName: project.name, data: assistantData[projectID] ?? AssistantData()) {
            self.workspace.session($0)?.name
        }
        do {
            try assistantStore.writePlanSnapshot(text, projectID: projectID)
        } catch {
            log.append(.error, "Couldn't write the plan for sessions in \(project.name)", detail: AppModel.describe(error))
        }
    }

    // MARK: - Skills

    /// Rereads a project's approved skills (at launch, and when a plan item
    /// or the sheet opens).
    public func refreshApprovedSkills(projectID: UUID) {
        let skills = assistantStore.approvedSkills(projectID: projectID)
        if approvedSkills[projectID] != skills { approvedSkills[projectID] = skills }
    }

    /// The skills picked for an item's opening prompt (see `SkillChips`).
    /// Files come from the item's sessions whose changes have loaded;
    /// `folderID` is the folder the new session is going in (items have none).
    public func suggestedSkills(forItem item: PlanItem, inProject projectID: UUID, folderID: UUID? = nil) -> [String] {
        let skills = approvedSkills[projectID] ?? []
        guard !skills.isEmpty, let project = workspace.project(projectID) else { return [] }
        var sessionIDs = Set(notes(forItem: item.id, inProject: projectID).compactMap(\.sessionID))
        if let sessionID = item.sessionID { sessionIDs.insert(sessionID) }
        let files = sessionIDs.flatMap { sessionChanges[$0]?.session?.absolutePaths.values.map { $0 } ?? [] }
            .compactMap { SkillChips.relativePath($0, projectPath: project.path) }
        let folder = folderID.flatMap { workspace.folder($0)?.name }
        return SkillChips.pick(from: skills, touchedFiles: Array(Set(files)).sorted(), folderName: folder).map(\.name)
    }

    // MARK: - Start Session from a plan item

    /// The session working on an item, while it still exists.
    public func session(workingOn item: PlanItem) -> Session? {
        item.sessionID.flatMap { workspace.session($0) }
    }

    /// Whether an item can start a session: it isn't done, and no session
    /// that still exists is working on it.
    public func canStartSession(fromItem item: PlanItem) -> Bool {
        item.status != .done && !(item.status == .inSession && session(workingOn: item) != nil)
    }

    /// The sheet's starting values: the item's title as the name, Unfiled
    /// (you pick the folder there), a role from the name, and the prompt
    /// with its skills.
    public func planSessionDraft(forItem item: PlanItem, inProject projectID: UUID) -> PlanSessionDraft {
        PlanSessionDraft(name: item.title, folderID: nil,
                         role: SessionRole.infer(fromName: item.title, roles: settings.roles),
                         promptBody: openingPromptBody(forItem: item, inProject: projectID),
                         skills: suggestedSkills(forItem: item, inProject: projectID))
    }

    /// The item's title, its notes (oldest first) and its issue.
    public func openingPromptBody(forItem item: PlanItem, inProject projectID: UUID) -> String {
        OpeningPrompt.body(title: item.title,
                           notes: notes(forItem: item.id, inProject: projectID).reversed().map(\.text),
                           issue: item.issue)
    }

    /// Start Session: a new session with the item's opening prompt and the
    /// chosen skills named in it. The item moves to In Session, linked to
    /// the session, once the session has been made; if its agent then fails
    /// to start, the item goes back to how it was.
    @discardableResult
    public func startSession(fromItem itemID: UUID, projectID: UUID, name: String, folderID: UUID?, role: SessionRole,
                             skills: [String], useWorktree: Bool) -> UUID? {
        guard let item = item(itemID, inProject: projectID) else {
            report("That plan item no longer exists, so no session was started.")
            return nil
        }
        // Checked here too, not only by the sheet: a stale sheet mustn't
        // unlink a live session or reopen a done item.
        guard canStartSession(fromItem: item) else { return nil }
        guard !isAssistantDataUnreadable(projectID) else {
            report("The assistant's notes for this project couldn't be read, so a session can't be started from its plan.")
            return nil
        }
        // Only approved skills are named.
        let approved = Set((approvedSkills[projectID] ?? []).map(\.name))
        let skills = skills.filter { approved.contains($0) }
        let prompt = OpeningPrompt.text(title: item.title,
                                        notes: notes(forItem: itemID, inProject: projectID).reversed().map(\.text),
                                        issue: item.issue, skills: skills)
        var request = NewSessionRequest(projectID: projectID, folderID: folderID, name: name, role: role, prompt: prompt,
                                        model: settings.defaultModel,
                                        permissionMode: settings.defaultPermissionMode(background: runsInBackground(prompt: prompt)))
        request.useWorktree = useWorktree
        request.namedSkills = skills
        guard let sessionID = createSession(request) else { return nil }
        var after = item
        after.status = .inSession
        after.sessionID = sessionID
        after.updatedAt = now()
        let entry = AuditEntry(at: now(), actor: .user, action: .itemChanged, beforeItem: item, afterItem: after,
                               cause: "ui")
        let session = workspace.session(sessionID)
        let linked = change(projectID: projectID, recording: entry, reportFailures: false) { data in
            if let index = data.items.firstIndex(where: { $0.id == itemID }) { data.items[index] = after }
        }
        guard linked else {
            report("Started “\(session?.name ?? name)”, but couldn't link it to “\(item.title)”. See the Activity Log.")
            return sessionID
        }
        log.append(.info, "Started a session for \"\(item.title)\"")
        // A background agent starts later; until it has, the item can go back.
        if session?.agentID == nil, session?.claudeSessionID == nil {
            pendingItemStarts[sessionID] = (projectID, item)
        }
        return sessionID
    }

    /// After a background agent's start: forget the item's old state, or,
    /// when it failed, put the item back (unless it has changed since).
    func finishItemStart(_ sessionID: UUID, started: Bool) {
        guard let pending = pendingItemStarts.removeValue(forKey: sessionID), !started,
              let current = item(pending.before.id, inProject: pending.projectID),
              current.sessionID == sessionID, current.status == .inSession
        else { return }
        var restored = pending.before
        restored.updatedAt = now()
        let entry = AuditEntry(at: now(), actor: .user, action: .itemChanged, beforeItem: current, afterItem: restored,
                               cause: sessionID.uuidString.lowercased())
        if change(projectID: pending.projectID, recording: entry, reportFailures: false, { data in
            if let index = data.items.firstIndex(where: { $0.id == restored.id }) { data.items[index] = restored }
        }) {
            log.append(.info, "Put \"\(restored.title)\" back to \(restored.status.label): its session didn't start")
        }
    }

    // MARK: - Notes from sessions

    /// The longest a session's note can be; the rest is cut.
    public static let sessionNoteLimit = 4000

    /// Reads notes sessions wrote with `claudio note` (polled with hook
    /// events, and at launch for any written while Claudio was closed).
    public func pollAssistantInbox() {
        let lines: [String]
        do {
            lines = try assistantStore.takeInbox()
            inboxFailing = false
        } catch {
            // Nothing is taken until its place can be saved, so no note is
            // read twice; they wait in the inbox until then.
            if !inboxFailing {
                log.append(.error, "Couldn't read notes from sessions", detail: AppModel.describe(error)
                           + "\nThey stay in the inbox and are read once this is fixed.")
            }
            inboxFailing = true
            return
        }
        for line in lines {
            guard let entry = InboxEntry.parse(line) else {
                log.append(.error, "Skipped a line in the assistant's inbox that couldn't be read", detail: line)
                continue
            }
            switch entry.command {
            case "note": addSessionNote(entry)
            default: log.append(.error, "Skipped an unknown command from a session: \(entry.command)")
            }
        }
    }

    private func addSessionNote(_ entry: InboxEntry) {
        let session = inboxSession(entry.sessionID)
        guard let projectID = session?.projectID ?? projectID(containing: entry.directory) else {
            log.append(.error, "A session wrote a note outside Claudio's projects, so it wasn't kept",
                       detail: entry.directory)
            return
        }
        // A note from the session working on an item goes with that item.
        let itemID = session.flatMap { session in
            items(inProject: projectID).first { $0.sessionID == session.id && $0.status != .done }?.id
        }
        let text = String(entry.text.prefix(AppModel.sessionNoteLimit))
        let project = workspace.project(projectID)?.name ?? "a project"
        guard let note = addNote(text, author: .session, projectID: projectID, sessionID: session?.id,
                                 itemID: itemID, cause: session?.id.uuidString.lowercased() ?? "session", reportFailures: false)
        else {
            // It arrived in the background, so it's logged rather than shown,
            // with its text, so it isn't lost (the line stays in inbox.log too).
            log.append(.error, "Couldn't save a note from \(session?.name ?? "a session") in \(project)", detail: text)
            return
        }
        log.append(.info, "\(session?.name ?? "A session") wrote a note", detail: note.itemID == nil ? nil : "Attached to its plan item")
    }

    /// The session an inbox line names: by its Claude Code id (background
    /// agents), or by Claudio's own id (direct tabs).
    private func inboxSession(_ id: String) -> Session? {
        guard !id.isEmpty else { return nil }
        if let session = workspace.session(claudeSessionID: id) { return session }
        return UUID(uuidString: id).flatMap { workspace.session($0) }
    }

    /// The project a directory is in: the longest project path containing
    /// it (a worktree is inside its repository).
    func projectID(containing directory: String) -> UUID? {
        workspace.projects
            .filter { directory == $0.path || directory.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }?.id
    }
}
