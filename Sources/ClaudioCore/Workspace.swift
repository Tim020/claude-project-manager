import Foundation

/// The persisted Project → Folder → Session hierarchy and every operation on it.
///
/// Sessions are stored flat; folders hold ordered session IDs. A session that is
/// in no folder belongs to its project's "Unfiled" group.
public struct Workspace: Codable, Equatable, Sendable {
    public static let unfiledName = "Unfiled"
    public static let defaultFolderName = "New Folder"

    public private(set) var projects: [Project]
    public private(set) var sessions: [Session]
    /// Open tabs, in the order they were opened (like a browser). Closing a
    /// tab never stops or removes the session.
    public private(set) var openTabIDs: [UUID]

    /// Sessions removed from Claudio but kept in Claude Code. They can be
    /// restored, and until then aren't imported again.
    public private(set) var removedSessions: [RemovedSession]
    /// Conversation ids and agent ids of sessions deleted from Claude Code
    /// too. Until `claude rm` finishes and the history files are gone,
    /// discovery and the agent list would otherwise bring them back.
    public private(set) var deletedClaudeSessionIDs: Set<String>
    public private(set) var deletedAgentIDs: Set<String>

    public var openSessionIDs: Set<UUID> { Set(openTabIDs) }

    enum CodingKeys: String, CodingKey {
        case projects, sessions
        case openTabIDs = "openSessionIDs"
        case removedSessions, deletedClaudeSessionIDs, deletedAgentIDs
    }

    public init(projects: [Project] = [], sessions: [Session] = [], openTabIDs: [UUID] = []) {
        self.projects = projects
        self.sessions = sessions
        self.openTabIDs = openTabIDs
        removedSessions = []
        deletedClaudeSessionIDs = []
        deletedAgentIDs = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([Project].self, forKey: .projects)
        sessions = try c.decode([Session].self, forKey: .sessions)
        openTabIDs = try c.decodeIfPresent([UUID].self, forKey: .openTabIDs) ?? []
        removedSessions = try c.decodeIfPresent([RemovedSession].self, forKey: .removedSessions) ?? []
        deletedClaudeSessionIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deletedClaudeSessionIDs) ?? []
        deletedAgentIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deletedAgentIDs) ?? []
    }

    // MARK: - Tabs

    public func isOpen(_ sessionID: UUID) -> Bool {
        openTabIDs.contains(sessionID)
    }

    /// Open tabs across every folder and project, in tab order.
    public var openTabSessions: [Session] {
        openTabIDs.compactMap { session($0) }.filter { !$0.isArchived }
    }

    /// Open tabs in a group, in the group's order.
    public func openSessions(in group: SessionGroup) -> [Session] {
        sessions(in: group).filter { openTabIDs.contains($0.id) }
    }

    /// Replaces a project's settings (matched by id).
    public mutating func replaceProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
    }

    public mutating func openTab(_ sessionID: UUID) {
        guard session(sessionID) != nil, !openTabIDs.contains(sessionID) else { return }
        openTabIDs.append(sessionID)
    }

    public mutating func closeTab(_ sessionID: UUID) {
        openTabIDs.removeAll { $0 == sessionID }
    }

    /// Closes every other tab, in any folder.
    public mutating func closeOtherTabs(keeping sessionID: UUID) {
        openTabIDs.removeAll { $0 != sessionID }
    }

    /// Open tabs before (left of) a tab, in tab order.
    public func tabIDs(leftOf sessionID: UUID) -> [UUID] {
        guard let index = openTabIDs.firstIndex(of: sessionID) else { return [] }
        return Array(openTabIDs[..<index])
    }

    /// Open tabs after (right of) a tab, in tab order.
    public func tabIDs(rightOf sessionID: UUID) -> [UUID] {
        guard let index = openTabIDs.firstIndex(of: sessionID) else { return [] }
        return Array(openTabIDs[(index + 1)...])
    }

    public mutating func closeTabs(leftOf sessionID: UUID) {
        let ids = Set(tabIDs(leftOf: sessionID))
        openTabIDs.removeAll { ids.contains($0) }
    }

    public mutating func closeTabs(rightOf sessionID: UUID) {
        let ids = Set(tabIDs(rightOf: sessionID))
        openTabIDs.removeAll { ids.contains($0) }
    }

    public mutating func closeAllTabs() {
        openTabIDs.removeAll()
    }

    public mutating func closeCompletedTabs() {
        let completed = Set(sessions.filter { $0.status == .completed }.map(\.id))
        openTabIDs.removeAll { completed.contains($0) }
    }

    public mutating func closeCompletedTabs(in group: SessionGroup) {
        let ids = Set(sessions(in: group).filter { $0.status == .completed }.map(\.id))
        openTabIDs.removeAll { ids.contains($0) }
    }

    // MARK: - Lookup

    public func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    public func project(atPath path: String) -> Project? {
        let normalized = Workspace.normalize(path: path)
        return projects.first { $0.path == normalized }
    }

    /// The project a session's working directory belongs to, counting Claude
    /// Code worktrees (`<repo>/.claude/worktrees/<name>`) as their repository.
    public func projectID(forWorkingDirectory directory: String) -> UUID? {
        let normalized = Workspace.normalize(path: directory)
        return (project(atPath: normalized) ?? Worktree.repositoryRoot(of: normalized).flatMap { project(atPath: $0) })?.id
    }

    public func folder(_ id: UUID) -> Folder? {
        for project in projects {
            if let folder = project.folders.first(where: { $0.id == id }) { return folder }
        }
        return nil
    }

    public func projectID(containingFolder folderID: UUID) -> UUID? {
        projects.first { $0.folders.contains { $0.id == folderID } }?.id
    }

    public func session(_ id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    public func session(claudeSessionID: String) -> Session? {
        sessions.first { $0.claudeSessionID == claudeSessionID }
    }

    public func group(of sessionID: UUID) -> SessionGroup? {
        guard let session = session(sessionID) else { return nil }
        if let folderID = folderID(containing: sessionID) { return .folder(folderID) }
        return .unfiled(projectID: session.projectID)
    }

    public func projectID(of group: SessionGroup) -> UUID? {
        switch group {
        case .folder(let id): return projectID(containingFolder: id)
        case .unfiled(let projectID): return project(projectID) == nil ? nil : projectID
        }
    }

    public func name(of group: SessionGroup) -> String {
        switch group {
        case .folder(let id): return folder(id)?.name ?? ""
        case .unfiled: return Workspace.unfiledName
        }
    }

    /// Visible (non-archived) sessions in a group. Folder order is the user's
    /// order; Unfiled is newest activity first.
    public func sessions(in group: SessionGroup) -> [Session] {
        switch group {
        case .folder(let id):
            guard let folder = folder(id) else { return [] }
            return folder.sessionIDs.compactMap { session($0) }.filter { !$0.isArchived }
        case .unfiled(let projectID):
            let filed = Set(project(projectID)?.folders.flatMap(\.sessionIDs) ?? [])
            return sessions
                .filter { $0.projectID == projectID && !filed.contains($0.id) && !$0.isArchived }
                .sorted { $0.lastActivity > $1.lastActivity }
        }
    }

    public func statusCounts(projectID: UUID? = nil) -> StatusCounts {
        var counts = StatusCounts()
        for session in sessions where !session.isArchived && (projectID == nil || session.projectID == projectID) {
            switch session.status {
            case .working: counts.working += 1
            case .awaitingInput: counts.awaitingInput += 1
            case .completed: counts.completed += 1
            }
        }
        return counts
    }

    // MARK: - Projects

    @discardableResult
    public mutating func addProject(path: String, name: String? = nil) -> UUID {
        let normalized = Workspace.normalize(path: path)
        if let existing = project(atPath: normalized) { return existing.id }
        let defaultName = (normalized as NSString).lastPathComponent
        let project = Project(name: Workspace.trimmed(name) ?? defaultName, path: normalized)
        projects.append(project)
        return project.id
    }

    public mutating func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        let removed = Set(sessions.filter { $0.projectID == id }.map(\.id))
        openTabIDs.removeAll { removed.contains($0) }
        sessions.removeAll { $0.projectID == id }
        removedSessions.removeAll { $0.session.projectID == id }
    }

    public func isCollapsed(_ group: SessionGroup) -> Bool {
        switch group {
        case .folder(let id): return folder(id)?.isCollapsed ?? false
        case .unfiled(let projectID): return project(projectID)?.isUnfiledCollapsed ?? false
        }
    }

    public mutating func toggleCollapsed(_ group: SessionGroup) {
        switch group {
        case .folder(let id):
            guard let (p, f) = folderIndex(id) else { return }
            projects[p].folders[f].isCollapsed.toggle()
        case .unfiled(let projectID):
            guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
            projects[index].isUnfiledCollapsed.toggle()
        }
    }

    public mutating func toggleCollapsed(_ projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].isCollapsed.toggle()
    }

    // MARK: - Folders

    @discardableResult
    public mutating func createFolder(in projectID: UUID, named name: String, containing sessionID: UUID? = nil) throws -> UUID {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw WorkspaceError.projectNotFound }
        let folder = Folder(name: Workspace.trimmed(name) ?? uniqueFolderName(in: projects[index]))
        projects[index].folders.append(folder)
        if let sessionID { try moveSession(sessionID, to: .folder(folder.id)) }
        return folder.id
    }

    public mutating func renameFolder(_ id: UUID, to name: String) throws {
        guard let newName = Workspace.trimmed(name) else { throw WorkspaceError.emptyName }
        guard let (p, f) = folderIndex(id) else { throw WorkspaceError.folderNotFound }
        projects[p].folders[f].name = newName
    }

    /// Deletes the folder; its sessions become Unfiled.
    public mutating func deleteFolder(_ id: UUID) {
        guard let (p, f) = folderIndex(id) else { return }
        projects[p].folders.remove(at: f)
    }

    public mutating func moveFolder(_ id: UUID, toProject projectID: UUID) throws {
        guard let destination = projects.firstIndex(where: { $0.id == projectID }) else { throw WorkspaceError.projectNotFound }
        guard let (p, f) = folderIndex(id) else { throw WorkspaceError.folderNotFound }
        guard projects[p].id != projectID else { return }
        let folder = projects[p].folders.remove(at: f)
        projects[destination].folders.append(folder)
        for sessionID in folder.sessionIDs {
            updateSession(sessionID) { $0.projectID = projectID }
        }
    }

    /// Archives the completed sessions in a group. Returns how many were archived.
    @discardableResult
    public mutating func archiveCompleted(in group: SessionGroup) -> Int {
        let ids = sessions(in: group).filter { $0.status == .completed }.map(\.id)
        for id in ids { updateSession(id) { $0.isArchived = true } }
        return ids.count
    }

    // MARK: - Sessions

    public mutating func addSession(_ session: Session, toFolder folderID: UUID? = nil) throws {
        guard project(session.projectID) != nil else { throw WorkspaceError.projectNotFound }
        if let folderID {
            guard let (p, f) = folderIndex(folderID) else { throw WorkspaceError.folderNotFound }
            guard projects[p].id == session.projectID else { throw WorkspaceError.folderNotInProject }
            sessions.append(session)
            projects[p].folders[f].sessionIDs.append(session.id)
        } else {
            sessions.append(session)
        }
    }

    /// Moves a session into a folder (optionally at a position) or to Unfiled.
    /// Moving into another project's folder re-homes the session to that project.
    public mutating func moveSession(_ sessionID: UUID, to group: SessionGroup, at index: Int? = nil) throws {
        guard session(sessionID) != nil else { throw WorkspaceError.sessionNotFound }
        let destinationProject: UUID
        switch group {
        case .folder(let folderID):
            guard let owner = projectID(containingFolder: folderID) else { throw WorkspaceError.folderNotFound }
            destinationProject = owner
        case .unfiled(let projectID):
            guard project(projectID) != nil else { throw WorkspaceError.projectNotFound }
            destinationProject = projectID
        }

        detachFromFolders(sessionID)
        updateSession(sessionID) { $0.projectID = destinationProject }

        if case .folder(let folderID) = group, let (p, f) = folderIndex(folderID) {
            var ids = projects[p].folders[f].sessionIDs
            let position = min(max(index ?? ids.count, 0), ids.count)
            ids.insert(sessionID, at: position)
            projects[p].folders[f].sessionIDs = ids
        }
    }

    /// Moves a session to just before another one (drag to reorder). Moving
    /// before an Unfiled session unfiles it; Unfiled has no manual order.
    public mutating func moveSession(_ sessionID: UUID, before targetID: UUID) throws {
        guard sessionID != targetID else { return }
        guard session(sessionID) != nil, let group = group(of: targetID) else { throw WorkspaceError.sessionNotFound }
        guard case .folder(let folderID) = group else {
            try moveSession(sessionID, to: group)
            return
        }
        try moveSession(sessionID, to: group)
        guard let (p, f) = folderIndex(folderID) else { return }
        var ids = projects[p].folders[f].sessionIDs
        ids.removeAll { $0 == sessionID }
        ids.insert(sessionID, at: ids.firstIndex(of: targetID) ?? ids.count)
        projects[p].folders[f].sessionIDs = ids
    }

    /// Removes a session from the sidebar but keeps it (and its folder) so
    /// it can be restored.
    public mutating func removeFromClaudio(_ id: UUID, at date: Date) {
        guard let session = session(id) else { return }
        removedSessions.append(RemovedSession(session: session, folderID: folderID(containing: id), removedAt: date))
        removeSession(id)
    }

    /// Puts a removed session back: in its folder if that's still in its
    /// project, otherwise Unfiled.
    public mutating func restoreSession(_ id: UUID) throws {
        guard let index = removedSessions.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.sessionNotFound }
        let removed = removedSessions[index]
        let folderID = removed.folderID.flatMap { folderID in
            folderIndex(folderID).flatMap { projects[$0.0].id == removed.session.projectID ? folderID : nil }
        }
        try addSession(removed.session, toFolder: folderID)
        removedSessions.remove(at: index)
    }

    /// Deletes a session for good (it's being deleted from Claude Code too).
    public mutating func deleteSession(_ id: UUID) {
        if let session = session(id) {
            if let claudeID = session.claudeSessionID { deletedClaudeSessionIDs.insert(claudeID) }
            if let agentID = session.agentID { deletedAgentIDs.insert(agentID) }
        }
        removeSession(id)
    }

    /// Forgets deleted agents that `claude agents` no longer lists: `claude rm` has finished.
    public mutating func forgetDeletedAgents(notIn listed: Set<String>) {
        if !deletedAgentIDs.isSubset(of: listed) { deletedAgentIDs.formIntersection(listed) }
    }

    /// Whether a conversation or agent belongs to a removed or deleted
    /// session, so mustn't be imported again.
    public func isRemoved(claudeSessionID: String?, agentID: String? = nil) -> Bool {
        if let claudeSessionID, deletedClaudeSessionIDs.contains(claudeSessionID)
            || removedSessions.contains(where: { $0.session.claudeSessionID == claudeSessionID }) {
            return true
        }
        if let agentID, deletedAgentIDs.contains(agentID) || removedSessions.contains(where: { $0.session.agentID == agentID }) {
            return true
        }
        return false
    }

    /// Archived sessions, most recently active first.
    public var archivedSessions: [Session] {
        sessions.filter(\.isArchived).sorted { $0.lastActivity > $1.lastActivity }
    }

    public mutating func unarchive(_ id: UUID) {
        updateSession(id) { $0.isArchived = false }
    }

    public mutating func removeSession(_ id: UUID) {
        openTabIDs.removeAll { $0 == id }
        detachFromFolders(id)
        sessions.removeAll { $0.id == id }
    }

    public mutating func renameSession(_ id: UUID, to name: String) throws {
        guard let newName = Workspace.trimmed(name) else { throw WorkspaceError.emptyName }
        guard session(id) != nil else { throw WorkspaceError.sessionNotFound }
        updateSession(id) { $0.name = newName; $0.hasCustomName = true }
    }

    public mutating func updateSession(_ id: UUID, _ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[index])
    }

    // MARK: - Helpers

    private func folderID(containing sessionID: UUID) -> UUID? {
        for project in projects {
            if let folder = project.folders.first(where: { $0.sessionIDs.contains(sessionID) }) { return folder.id }
        }
        return nil
    }

    private func folderIndex(_ id: UUID) -> (Int, Int)? {
        for (p, project) in projects.enumerated() {
            if let f = project.folders.firstIndex(where: { $0.id == id }) { return (p, f) }
        }
        return nil
    }

    private mutating func detachFromFolders(_ sessionID: UUID) {
        for p in projects.indices {
            for f in projects[p].folders.indices {
                projects[p].folders[f].sessionIDs.removeAll { $0 == sessionID }
            }
        }
    }

    private func uniqueFolderName(in project: Project) -> String {
        let existing = Set(project.folders.map(\.name))
        var candidate = Workspace.defaultFolderName
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(Workspace.defaultFolderName) \(n)"
            n += 1
        }
        return candidate
    }

    static func trimmed(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func normalize(path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// A session removed from Claudio (but not from Claude Code), kept so it
/// can be restored.
public struct RemovedSession: Codable, Equatable, Sendable, Identifiable {
    public var session: Session
    /// The folder it was in; nil for Unfiled.
    public var folderID: UUID?
    public var removedAt: Date

    public var id: UUID { session.id }

    public init(session: Session, folderID: UUID?, removedAt: Date) {
        self.session = session
        self.folderID = folderID
        self.removedAt = removedAt
    }
}

/// What deleting a session removes.
public enum SessionDeletion: Sendable {
    /// Only Claudio's entry. Claude Code keeps the conversation (and any
    /// background agent), and Claudio doesn't import it again.
    case claudioOnly
    /// Claudio's entry, the background agent (`claude rm`) and the
    /// conversation's history files, which `claude rm` leaves behind.
    case everywhere
}
