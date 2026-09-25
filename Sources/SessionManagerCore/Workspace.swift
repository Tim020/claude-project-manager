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

    public init(projects: [Project] = [], sessions: [Session] = []) {
        self.projects = projects
        self.sessions = sessions
    }

    // MARK: - Lookup

    public func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    public func project(atPath path: String) -> Project? {
        let normalized = Workspace.normalize(path: path)
        return projects.first { $0.path == normalized }
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
        sessions.removeAll { $0.projectID == id }
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

    public mutating func removeSession(_ id: UUID) {
        detachFromFolders(id)
        sessions.removeAll { $0.id == id }
    }

    public mutating func renameSession(_ id: UUID, to name: String) throws {
        guard let newName = Workspace.trimmed(name) else { throw WorkspaceError.emptyName }
        guard session(id) != nil else { throw WorkspaceError.sessionNotFound }
        updateSession(id) { $0.name = newName }
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
