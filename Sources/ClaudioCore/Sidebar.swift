import Foundation

public struct SidebarFolder: Identifiable, Equatable, Sendable {
    public var id: String
    public var group: SessionGroup
    public var name: String
    public var isUnfiled: Bool
    public var isCollapsed: Bool
    /// How deep it's nested: 0 for a top-level folder (or Unfiled), 1 for one
    /// inside that, and so on. `SidebarProject.folders` is a flattened,
    /// pre-order walk of the tree (a folder right after its parent), so the
    /// view renders it with one flat `ForEach`, indenting by this.
    public var depth: Int = 0
    /// Its own direct sessions shown (empty when collapsed, unless filtering).
    public var sessions: [Session]
    /// Every session in its whole subtree the filters show, for the count
    /// badge (a folder's count includes its subfolders', like a disk usage
    /// view).
    public var sessionCount: Int
    /// Subtree sessions in each state that the filters show (collapsing
    /// doesn't change it), for the folder's pills.
    public var statusCounts = StatusCounts()
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
    /// Sessions in each state that the filters show, for the project header.
    public var statusCounts: StatusCounts
}

/// What's being dragged in the sidebar, carried as a string. A session is its
/// bare UUID (as it always has been); folders and projects are prefixed.
public enum SidebarDragItem: Equatable, Sendable {
    case session(UUID)
    case folder(UUID)
    case project(UUID)

    public var payload: String {
        switch self {
        case .session(let id): return id.uuidString
        case .folder(let id): return "folder:" + id.uuidString
        case .project(let id): return "project:" + id.uuidString
        }
    }

    public init?(payload: String) {
        if let id = UUID(uuidString: payload) {
            self = .session(id)
        } else if payload.hasPrefix("folder:"), let id = UUID(uuidString: String(payload.dropFirst("folder:".count))) {
            self = .folder(id)
        } else if payload.hasPrefix("project:"), let id = UUID(uuidString: String(payload.dropFirst("project:".count))) {
            self = .project(id)
        } else {
            return nil
        }
    }
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

    /// A folder's build result: its (and its subtree's) flattened rows, plus
    /// what its ancestor needs for its own pill and visibility. An ancestor
    /// that didn't match its own filters still shows when `rows` here is
    /// non-empty, so something nested inside it is still reachable.
    private struct Built {
        var rows: [SidebarFolder]
        /// Every filtered session in its subtree, for the parent's own pill
        /// and, at the top level, the project header's total (counted once
        /// per session, since top-level subtrees never overlap).
        var subtreeSessions: [Session]
    }

    public static func build(_ workspace: Workspace, filter: String, status: SessionStatus? = nil,
                             activeSince: Date? = nil, alwaysShow: Set<UUID> = [], home: String) -> [SidebarProject] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let textFiltering = !query.isEmpty
        let filtering = textFiltering || status != nil

        func matches(_ text: String) -> Bool { text.lowercased().contains(query) }

        /// Applies the recency/status/text filters to a folder's direct
        /// sessions, same rules as before nesting existed: recency only
        /// hides a folder that had sessions and lost them all; status and
        /// text filtering hide a folder with none left, even if it started
        /// with none. `nameMatches` already folds in every ancestor's name
        /// (and the project's), so a match anywhere above skips text
        /// filtering here too.
        func filteredDirect(_ raw: [Session], nameMatches: Bool) -> (sessions: [Session], hiddenByFilter: Bool) {
            var sessions = raw
            if activeSince != nil && !sessions.isEmpty {
                sessions = sessions.filter { isRecent($0, since: activeSince, alwaysShow: alwaysShow) }
                if sessions.isEmpty { return (sessions, true) }
            }
            if let status {
                sessions = sessions.filter { $0.status == status }
                if sessions.isEmpty { return (sessions, true) }
            }
            if textFiltering && !nameMatches {
                sessions = sessions.filter { matches($0.name) || matches($0.summary) }
                if sessions.isEmpty { return (sessions, true) }
            }
            return (sessions, false)
        }

        // `ancestors` guards against a cycle that somehow made it past
        // decode-time sanitization (every other tree walk in `Workspace`
        // guards the same way): without it, a cycle would recurse forever.
        func buildFolder(_ folder: Folder, in project: Project, depth: Int, ancestorMatches: Bool, ancestors: Set<UUID>) -> Built {
            guard !ancestors.contains(folder.id) else { return Built(rows: [], subtreeSessions: []) }
            let ancestors = ancestors.union([folder.id])
            let nameMatches = ancestorMatches || (textFiltering && matches(folder.name))
            let children = project.folders.filter { $0.parentID == folder.id }
            let builtChildren = children.map { buildFolder($0, in: project, depth: depth + 1, ancestorMatches: nameMatches, ancestors: ancestors) }
            let childRows = builtChildren.flatMap(\.rows)
            let childSubtreeSessions = builtChildren.flatMap(\.subtreeSessions)

            let (direct, hiddenByFilter) = filteredDirect(workspace.sessions(in: .folder(folder.id)), nameMatches: nameMatches)
            // An ancestor whose own sessions were filtered away (recency,
            // status or text alike) still shows, with none of its own rows,
            // when a descendant anywhere underneath it survived: otherwise
            // there'd be no path down to that descendant at all. This holds
            // for every filter, recency included — a folder whose sessions
            // merely aged out is no different here from one that was always
            // empty (`testFilterKeepsAncestorsOfASurvivingDeepDescendant`).
            guard !hiddenByFilter || !childRows.isEmpty else { return Built(rows: [], subtreeSessions: []) }

            let subtreeSessions = direct + childSubtreeSessions
            let collapsed = workspace.isCollapsed(.folder(folder.id))
            let showContents = !collapsed || filtering
            let row = SidebarFolder(id: folder.id.uuidString, group: .folder(folder.id), name: folder.name, isUnfiled: false,
                                    isCollapsed: collapsed, depth: depth, sessions: showContents ? direct : [],
                                    sessionCount: subtreeSessions.count, statusCounts: StatusCounts(subtreeSessions))
            return Built(rows: [row] + (showContents ? childRows : []), subtreeSessions: subtreeSessions)
        }

        return workspace.projects.compactMap { project -> SidebarProject? in
            let projectMatches = textFiltering && matches(project.name)

            let topLevel = project.folders.filter { $0.parentID == nil }
            let builtTop = topLevel.map { buildFolder($0, in: project, depth: 0, ancestorMatches: projectMatches, ancestors: []) }
            var folders = builtTop.flatMap(\.rows)

            let unfiledGroup = SessionGroup.unfiled(projectID: project.id)
            var unfiledSessions = workspace.sessions(in: unfiledGroup)
            if activeSince != nil && !unfiledSessions.isEmpty {
                unfiledSessions = unfiledSessions.filter { isRecent($0, since: activeSince, alwaysShow: alwaysShow) }
            }
            if let status { unfiledSessions = unfiledSessions.filter { $0.status == status } }
            if textFiltering && !projectMatches && !matches(Workspace.unfiledName) {
                unfiledSessions = unfiledSessions.filter { matches($0.name) || matches($0.summary) }
            }
            if !unfiledSessions.isEmpty {
                let collapsed = workspace.isCollapsed(unfiledGroup)
                folders.append(SidebarFolder(id: "unfiled-\(project.id.uuidString)", group: unfiledGroup, name: Workspace.unfiledName,
                                             isUnfiled: true, isCollapsed: collapsed, depth: 0,
                                             sessions: collapsed && !filtering ? [] : unfiledSessions,
                                             sessionCount: unfiledSessions.count, statusCounts: StatusCounts(unfiledSessions)))
            }

            if filtering && folders.isEmpty && (status != nil || !projectMatches) { return nil }

            let all = workspace.sessions.filter { $0.projectID == project.id && !$0.isArchived }
            let active = all.filter { $0.status != .completed }
            let projectTotal = StatusCounts(builtTop.flatMap(\.subtreeSessions) + unfiledSessions)
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
                statusCounts: projectTotal)
        }
    }
}
