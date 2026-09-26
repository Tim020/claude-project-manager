import Foundation

public struct SidebarFolder: Identifiable, Equatable, Sendable {
    public var id: String
    public var group: SessionGroup
    public var name: String
    public var isUnfiled: Bool
    public var isCollapsed: Bool
    /// Sessions shown (empty when collapsed, unless filtering).
    public var sessions: [Session]
    /// All visible sessions in the group, for the count badge.
    public var sessionCount: Int
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
    /// Sessions in each state (not archived), for the project header.
    public var statusCounts: StatusCounts
}

/// Builds the Project → Folder → Session source list, applying the filter
/// field and, optionally, a status filter and a recent-activity window.
public enum Sidebar {
    /// Whether a session shows under the recent-activity window: active since
    /// the cutoff, still working or awaiting input, or in `alwaysShow` (open
    /// tabs, the selection).
    static func isRecent(_ session: Session, since: Date?, alwaysShow: Set<UUID>) -> Bool {
        guard let since else { return true }
        return session.lastActivity >= since || session.status != .completed || alwaysShow.contains(session.id)
    }

    /// Sessions the recent-activity window hides.
    public static func hiddenByRecency(_ workspace: Workspace, activeSince: Date?, alwaysShow: Set<UUID>) -> Int {
        guard activeSince != nil else { return 0 }
        return workspace.projects.reduce(0) { total, project in
            var groups: [SessionGroup] = project.folders.map { .folder($0.id) }
            groups.append(.unfiled(projectID: project.id))
            return total + groups.reduce(0) { count, group in
                count + workspace.sessions(in: group).filter { !isRecent($0, since: activeSince, alwaysShow: alwaysShow) }.count
            }
        }
    }

    public static func build(_ workspace: Workspace, filter: String, status: SessionStatus? = nil,
                             activeSince: Date? = nil, alwaysShow: Set<UUID> = [], home: String) -> [SidebarProject] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let textFiltering = !query.isEmpty
        let filtering = textFiltering || status != nil

        func matches(_ text: String) -> Bool { text.lowercased().contains(query) }

        return workspace.projects.compactMap { project -> SidebarProject? in
            let projectMatches = textFiltering && matches(project.name)

            var groups: [(SessionGroup, String, Bool)] = project.folders.map { (.folder($0.id), $0.name, false) }
            groups.append((.unfiled(projectID: project.id), Workspace.unfiledName, true))

            var folders: [SidebarFolder] = []
            for (group, name, isUnfiled) in groups {
                var sessions = workspace.sessions(in: group)
                if activeSince != nil && !sessions.isEmpty {
                    sessions = sessions.filter { isRecent($0, since: activeSince, alwaysShow: alwaysShow) }
                    // Hide folders whose sessions are all old; keep ones that are simply empty.
                    if sessions.isEmpty { continue }
                }
                if let status {
                    sessions = sessions.filter { $0.status == status }
                    if sessions.isEmpty { continue }
                }
                if textFiltering && !projectMatches && !matches(name) {
                    sessions = sessions.filter { matches($0.name) || matches($0.summary) }
                    if sessions.isEmpty { continue }
                }
                if isUnfiled && sessions.isEmpty { continue }
                let id: String
                switch group {
                case .folder(let folderID): id = folderID.uuidString
                case .unfiled(let projectID): id = "unfiled-\(projectID.uuidString)"
                }
                let collapsed = workspace.isCollapsed(group)
                folders.append(SidebarFolder(id: id, group: group, name: name, isUnfiled: isUnfiled, isCollapsed: collapsed,
                                             sessions: collapsed && !filtering ? [] : sessions, sessionCount: sessions.count))
            }

            if filtering && folders.isEmpty && (status != nil || !projectMatches) { return nil }

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
                hasAwaitingInput: active.contains { $0.status == .awaitingInput },
                statusCounts: workspace.statusCounts(projectID: project.id))
        }
    }
}
