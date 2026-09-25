import Foundation

public struct SidebarFolder: Identifiable, Equatable, Sendable {
    public var id: String
    public var group: SessionGroup
    public var name: String
    public var isUnfiled: Bool
    public var sessions: [Session]
}

public struct SidebarProject: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var displayPath: String
    public var initials: String
    public var isCollapsed: Bool
    public var folders: [SidebarFolder]
    /// Working + awaiting input sessions (badge on the project).
    public var activeCount: Int
    public var hasAwaitingInput: Bool
}

/// Builds the Project → Folder → Session source list, applying the filter field.
public enum Sidebar {
    public static func build(_ workspace: Workspace, filter: String, home: String) -> [SidebarProject] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtering = !query.isEmpty

        func matches(_ text: String) -> Bool { text.lowercased().contains(query) }

        return workspace.projects.compactMap { project -> SidebarProject? in
            let projectMatches = filtering && matches(project.name)

            var groups: [(SessionGroup, String, Bool)] = project.folders.map { (.folder($0.id), $0.name, false) }
            groups.append((.unfiled(projectID: project.id), Workspace.unfiledName, true))

            var folders: [SidebarFolder] = []
            for (group, name, isUnfiled) in groups {
                var sessions = workspace.sessions(in: group)
                if filtering && !projectMatches && !matches(name) {
                    sessions = sessions.filter { matches($0.name) || matches($0.summary) }
                    if sessions.isEmpty { continue }
                }
                if isUnfiled && sessions.isEmpty { continue }
                let id: String
                switch group {
                case .folder(let folderID): id = folderID.uuidString
                case .unfiled(let projectID): id = "unfiled-\(projectID.uuidString)"
                }
                folders.append(SidebarFolder(id: id, group: group, name: name, isUnfiled: isUnfiled, sessions: sessions))
            }

            if filtering && folders.isEmpty && !projectMatches { return nil }

            let all = workspace.sessions.filter { $0.projectID == project.id && !$0.isArchived }
            let active = all.filter { $0.status != .completed }
            return SidebarProject(
                id: project.id,
                name: project.name,
                path: project.path,
                displayPath: PathDisplay.abbreviated(project.path, home: home),
                initials: PathDisplay.initials(project.name),
                isCollapsed: project.isCollapsed,
                folders: project.isCollapsed && !filtering ? [] : folders,
                activeCount: active.count,
                hasAwaitingInput: active.contains { $0.status == .awaitingInput })
        }
    }
}
