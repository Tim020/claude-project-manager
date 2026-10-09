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
    /// tab never stops or removes the session. A tab is a session's id, or an
    /// overview tab's (`overviewTabs`).
    public private(set) var openTabIDs: [UUID] {
        didSet {
            panes.reconcile(openTabIDs: openTabIDs)
            // An overview tab lasts only while it's open.
            if overviewTabs.contains(where: { !openTabIDs.contains($0.id) }) {
                overviewTabs.removeAll { !openTabIDs.contains($0.id) }
            }
        }
    }
    /// Open tabs that show a project's or folder's pull requests rather than a
    /// session. They sit in panes like session tabs.
    public private(set) var overviewTabs: [OverviewTab]
    /// How the open tabs are arranged into panes; always holds exactly the open tabs.
    public private(set) var panes: PaneLayout

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
        case projects, sessions, panes
        case openTabIDs = "openSessionIDs"
        case removedSessions, deletedClaudeSessionIDs, deletedAgentIDs, overviewTabs
    }

    public init(projects: [Project] = [], sessions: [Session] = [], openTabIDs: [UUID] = []) {
        self.projects = projects
        self.sessions = sessions
        self.openTabIDs = openTabIDs
        overviewTabs = []
        removedSessions = []
        deletedClaudeSessionIDs = []
        deletedAgentIDs = []
        panes = PaneLayout(tabIDs: [])
        panes.reconcile(openTabIDs: openTabIDs)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([Project].self, forKey: .projects)
        sessions = try c.decode([Session].self, forKey: .sessions)
        removedSessions = try c.decodeIfPresent([RemovedSession].self, forKey: .removedSessions) ?? []
        deletedClaudeSessionIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deletedClaudeSessionIDs) ?? []
        deletedAgentIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deletedAgentIDs) ?? []
        overviewTabs = []
        openTabIDs = []
        // A layout that doesn't decode just starts again as one pane.
        panes = ((try? c.decodeIfPresent(PaneLayout.self, forKey: .panes)) ?? nil) ?? PaneLayout()

        // Older files kept archived sessions' tabs open (hidden); archiving closes
        // them now, so drop those, and any id without a session. Overview tabs
        // whose project or folder has gone are dropped too.
        // Tolerant like `panes`: an overview tab is easily opened again.
        let savedOverviews = ((try? c.decodeIfPresent([OverviewTab].self, forKey: .overviewTabs)) ?? nil) ?? []
        let overviews = savedOverviews.filter { projectID(of: $0.overview) != nil }
        let visible = Set(sessions.filter { !$0.isArchived }.map(\.id)).union(overviews.map(\.id))
        let open = (try c.decodeIfPresent([UUID].self, forKey: .openTabIDs) ?? []).filter(visible.contains)
        overviewTabs = overviews.filter { open.contains($0.id) }
        openTabIDs = open
        panes.reconcile(openTabIDs: openTabIDs)
    }

    // MARK: - Panes

    /// Shows a tab in its pane and focuses that pane, opening the tab (in the
    /// focused pane) if it isn't open.
    public mutating func selectTab(_ sessionID: UUID) {
        openTab(sessionID)
        panes.select(sessionID)
    }

    public mutating func focusPane(_ groupID: UUID) {
        panes.focus(groupID)
    }

    /// Moves a tab into a pane (opening it if needed), before `index` or at the end.
    public mutating func moveTab(_ sessionID: UUID, toPane groupID: UUID, at index: Int? = nil) {
        openTab(sessionID)
        panes.move(sessionID, toGroup: groupID, at: index)
    }

    /// Moves a tab (opening it if needed) into a new pane docked to an edge of a pane.
    public mutating func splitTab(_ sessionID: UUID, to edge: PaneEdge, of groupID: UUID) {
        openTab(sessionID)
        panes.split(sessionID, to: edge, of: groupID)
    }

    public mutating func resizeSplit(_ splitID: UUID, fractions: [Double]) {
        panes.resize(splitID, fractions: fractions)
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
        guard isTab(sessionID), !openTabIDs.contains(sessionID) else { return }
        openTabIDs.append(sessionID)
    }

    /// Whether `id` can be a tab: a session, or an open overview tab.
    public func isTab(_ id: UUID) -> Bool {
        session(id) != nil || overviewTab(id) != nil
    }

    public func overviewTab(_ id: UUID) -> OverviewTab? {
        overviewTabs.first { $0.id == id }
    }

    /// Opens an overview in the focused pane, or shows it where it's already
    /// open (one tab per overview), and focuses it. Returns the tab's id.
    @discardableResult
    public mutating func openOverview(_ overview: Overview) -> UUID? {
        guard projectID(of: overview) != nil else { return nil }
        let id: UUID
        if let existing = overviewTabs.first(where: { $0.overview == overview }) {
            id = existing.id
        } else {
            id = UUID()
            overviewTabs.append(OverviewTab(id: id, overview: overview))
        }
        selectTab(id)
        return id
    }

    /// The project an overview belongs to; nil once it (or its folder) is gone.
    public func projectID(of overview: Overview) -> UUID? {
        switch overview {
        case .project(let id): return project(id) == nil ? nil : id
        case .folder(let group): return projectID(of: group)
        }
    }

    public mutating func closeTab(_ sessionID: UUID) {
        openTabIDs.removeAll { $0 == sessionID }
    }

    /// Closes several tabs in one change.
    public mutating func closeTabs(_ ids: Set<UUID>) {
        openTabIDs.removeAll { ids.contains($0) }
    }

    /// Closes the other tabs in a tab's pane.
    public mutating func closeOtherTabs(keeping sessionID: UUID) {
        let others = Set(panes.group(containing: sessionID)?.tabIDs ?? []).subtracting([sessionID])
        openTabIDs.removeAll { others.contains($0) }
    }

    /// Tabs before (left of) a tab in its pane.
    public func tabIDs(leftOf sessionID: UUID) -> [UUID] {
        guard let tabs = panes.group(containing: sessionID)?.tabIDs, let index = tabs.firstIndex(of: sessionID) else { return [] }
        return Array(tabs[..<index])
    }

    /// Tabs after (right of) a tab in its pane.
    public func tabIDs(rightOf sessionID: UUID) -> [UUID] {
        guard let tabs = panes.group(containing: sessionID)?.tabIDs, let index = tabs.firstIndex(of: sessionID) else { return [] }
        return Array(tabs[(index + 1)...])
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

    /// Closes the completed tabs in a group (a folder's whole subtree, not
    /// just its direct sessions).
    public mutating func closeCompletedTabs(in group: SessionGroup) {
        let ids = Set(sessionsInSubtree(group).filter { $0.status == .completed }.map(\.id))
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

    /// A folder's name and every ancestor's, innermost first ("OAuth",
    /// "Auth", "Backend"). Bounded against a corrupted cycle the same way
    /// `sanitizedFolders` guards against one existing.
    public func folderAndAncestorNames(of id: UUID) -> [String] {
        var names: [String] = []
        var current: UUID? = id
        var seen: Set<UUID> = []
        while let currentID = current, let folder = folder(currentID), seen.insert(currentID).inserted {
            names.append(folder.name)
            current = folder.parentID
        }
        return names
    }

    /// A group's full ancestry, outermost first ("Backend › Auth › OAuth"),
    /// for places with no surrounding tree to show nesting visually
    /// (breadcrumbs, pickers, PR group headers).
    public func path(of group: SessionGroup) -> String {
        switch group {
        case .unfiled: return Workspace.unfiledName
        case .folder(let id): return folderAndAncestorNames(of: id).reversed().joined(separator: " › ")
        }
    }

    /// A folder's id plus every folder nested under it, at any depth.
    public func subtreeFolderIDs(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier: Set<UUID> = [id]
        let all = projects.flatMap(\.folders)
        while !frontier.isEmpty {
            let children = Set(all.filter { folder in folder.parentID.map(frontier.contains) ?? false }.map(\.id))
                .subtracting(result)
            guard !children.isEmpty else { break }
            result.formUnion(children)
            frontier = children
        }
        return result
    }

    /// Whether `candidate` is `ancestor` itself or nested somewhere under it.
    public func isFolder(_ candidate: UUID, orDescendantOf ancestor: UUID) -> Bool {
        subtreeFolderIDs(of: ancestor).contains(candidate)
    }

    /// A project's folders in sidebar order: a pre-order walk of the tree (a
    /// folder right after its parent, children in their sibling order), with
    /// each one's nesting depth (0 for top-level). Cycle-safe.
    public func foldersInDisplayOrder(projectID: UUID) -> [(folder: Folder, depth: Int)] {
        guard let project = project(projectID) else { return [] }
        var result: [(Folder, Int)] = []
        var visited: Set<UUID> = []
        func visit(parentID: UUID?, depth: Int) {
            for folder in project.folders where folder.parentID == parentID {
                guard visited.insert(folder.id).inserted else { continue }
                result.append((folder, depth))
                visit(parentID: folder.id, depth: depth + 1)
            }
        }
        visit(parentID: nil, depth: 0)
        return result
    }

    /// Where a folder could move via "Move to Folder": its project's
    /// folders in display order, minus its own subtree (it can't move into
    /// itself or one of its own subfolders) and its current parent (that's
    /// already where it is).
    public func moveToFolderCandidates(for id: UUID) -> [(folder: Folder, depth: Int)] {
        guard let projectID = projectID(containingFolder: id) else { return [] }
        let currentParentID = folder(id)?.parentID
        let subtree = subtreeFolderIDs(of: id)
        return foldersInDisplayOrder(projectID: projectID).filter { !subtree.contains($0.folder.id) && $0.folder.id != currentParentID }
    }

    /// Visible (non-archived) sessions in a group. Folder order is the user's
    /// order; Unfiled is newest activity first. For a folder this is its
    /// direct sessions only; see `sessionsInSubtree` for everything nested
    /// underneath it too.
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

    /// Every (non-archived) session anywhere under a folder: its own direct
    /// sessions plus every nested subfolder's, at any depth. Unfiled has no
    /// subtree, so this is the same as `sessions(in:)` for it. Used for
    /// folder-level aggregates (status pills, pull request chips, Archive
    /// Completed, Close Completed Tabs), which roll up the whole subtree.
    public func sessionsInSubtree(_ group: SessionGroup) -> [Session] {
        switch group {
        case .unfiled: return sessions(in: group)
        case .folder(let id):
            let ids = subtreeFolderIDs(of: id)
            let filed = Set(projects.flatMap(\.folders).filter { ids.contains($0.id) }.flatMap(\.sessionIDs))
            return sessions.filter { filed.contains($0.id) && !$0.isArchived }
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
        var removed = Set(sessions.filter { $0.projectID == id }.map(\.id))
        removed.formUnion(overviewTabs.filter { projectID(of: $0.overview) == id }.map(\.id))
        projects.removeAll { $0.id == id }
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

    /// Creates a folder, nested inside `parentID` or at the project's top
    /// level when nil. The default name is unique among its siblings, not
    /// every folder in the project.
    @discardableResult
    public mutating func createFolder(in projectID: UUID, named name: String, containing sessionID: UUID? = nil,
                                      parentID: UUID? = nil) throws -> UUID {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw WorkspaceError.projectNotFound }
        if let parentID {
            guard folder(parentID) != nil else { throw WorkspaceError.folderNotFound }
            guard self.projectID(containingFolder: parentID) == projectID else { throw WorkspaceError.folderNotInProject }
        }
        let folder = Folder(name: Workspace.trimmed(name) ?? uniqueFolderName(in: projects[index], parentID: parentID), parentID: parentID)
        projects[index].folders.append(folder)
        if let sessionID { try moveSession(sessionID, to: .folder(folder.id)) }
        return folder.id
    }

    public mutating func renameFolder(_ id: UUID, to name: String) throws {
        guard let newName = Workspace.trimmed(name) else { throw WorkspaceError.emptyName }
        guard let (p, f) = folderIndex(id) else { throw WorkspaceError.folderNotFound }
        projects[p].folders[f].name = newName
    }

    /// What happens to a deleted folder's contents.
    public enum FolderDeletionMode: Sendable {
        /// Its direct subfolders and sessions move up one level, into its
        /// parent (or the project's top level / Unfiled, if it had none).
        case promoteChildren
        /// Its whole subtree goes: every nested subfolder is gone, and every
        /// session anywhere inside it (at any depth) becomes Unfiled.
        case flattenToUnfiled
    }

    /// Deletes the folder. `mode` decides what happens to anything nested
    /// inside it; closes the overview tab of every folder removed.
    public mutating func deleteFolder(_ id: UUID, mode: FolderDeletionMode = .promoteChildren) {
        guard let (p, f) = folderIndex(id) else { return }
        let folder = projects[p].folders[f]
        var removedIDs: Set<UUID> = [id]

        switch mode {
        case .promoteChildren:
            // Writes `parentID` directly rather than going through
            // `relocateFolder`'s validated path: it's safe here only because
            // the deleted folder's own `parentID` was already validated when
            // it was placed, and its direct children can't be an ancestor of
            // anything (so reparenting them to it can't create a cycle). If
            // that parent has still gone missing somehow, fail loudly in
            // testing rather than let its sessions vanish from every
            // folder's `sessionIDs` without a trace.
            for i in projects[p].folders.indices where projects[p].folders[i].parentID == id {
                projects[p].folders[i].parentID = folder.parentID
            }
            if let parentID = folder.parentID {
                if let pf = projects[p].folders.firstIndex(where: { $0.id == parentID }) {
                    projects[p].folders[pf].sessionIDs.append(contentsOf: folder.sessionIDs)
                } else {
                    assertionFailure("Folder \(id)'s parent \(parentID) should still exist")
                }
            }
            projects[p].folders.remove(at: f)
        case .flattenToUnfiled:
            removedIDs = subtreeFolderIDs(of: id)
            projects[p].folders.removeAll { removedIDs.contains($0.id) }
        }

        let overviews = Set(overviewTabs.filter {
            if case .folder(.folder(let groupID)) = $0.overview { return removedIDs.contains(groupID) }
            return false
        }.map(\.id))
        if !overviews.isEmpty { openTabIDs.removeAll { overviews.contains($0) } }
    }

    /// Where a relocated folder lands among its new siblings.
    private enum FolderPlacement {
        case end
        case beforeSibling(UUID)
        case afterSibling(UUID)
    }

    /// The shared move: reparents a folder (optionally into a different
    /// project, carrying its whole subtree and re-homing those sessions),
    /// then positions it among its new siblings. Guards against moving a
    /// folder into itself or one of its own subfolders.
    private mutating func relocateFolder(_ id: UUID, parentID: UUID?, projectID: UUID, placement: FolderPlacement) throws {
        guard id != parentID else { throw WorkspaceError.cyclicFolderMove }
        guard folderIndex(id) != nil else { throw WorkspaceError.folderNotFound }
        guard let destination = projects.firstIndex(where: { $0.id == projectID }) else { throw WorkspaceError.projectNotFound }
        if let parentID {
            guard folder(parentID) != nil else { throw WorkspaceError.folderNotFound }
            guard self.projectID(containingFolder: parentID) == projectID else { throw WorkspaceError.folderNotInProject }
            guard !isFolder(parentID, orDescendantOf: id) else { throw WorkspaceError.cyclicFolderMove }
        }

        if let (sp, _) = folderIndex(id), projects[sp].id != projectID {
            let subtreeIDs = subtreeFolderIDs(of: id)
            let moving = projects[sp].folders.filter { subtreeIDs.contains($0.id) }
            projects[sp].folders.removeAll { subtreeIDs.contains($0.id) }
            projects[destination].folders.append(contentsOf: moving)
            for folderID in subtreeIDs {
                for sessionID in folder(folderID)?.sessionIDs ?? [] { updateSession(sessionID) { $0.projectID = projectID } }
            }
        }

        guard let (p, f) = folderIndex(id) else { throw WorkspaceError.folderNotFound }
        var moved = projects[p].folders.remove(at: f)
        moved.parentID = parentID
        let index: Int
        switch placement {
        case .end:
            index = projects[p].folders.count
        case .beforeSibling(let siblingID):
            guard let siblingIndex = projects[p].folders.firstIndex(where: { $0.id == siblingID }) else { throw WorkspaceError.folderNotFound }
            index = siblingIndex
        case .afterSibling(let siblingID):
            guard let siblingIndex = projects[p].folders.firstIndex(where: { $0.id == siblingID }) else { throw WorkspaceError.folderNotFound }
            index = siblingIndex + 1
        }
        projects[p].folders.insert(moved, at: index)
    }

    /// Moves a folder (and its whole subtree) to a project's top level, last;
    /// re-homes its subtree's sessions when that's a different project.
    public mutating func moveFolder(_ id: UUID, toProject projectID: UUID) throws {
        try relocateFolder(id, parentID: nil, projectID: projectID, placement: .end)
    }

    /// Nests a folder (and its whole subtree) inside another, as its last
    /// child; re-homes it (and its subtree's sessions) if that's a different
    /// project. Throws `.cyclicFolderMove` for a folder's own descendant.
    public mutating func moveFolder(_ id: UUID, intoFolder parentID: UUID) throws {
        guard let projectID = self.projectID(containingFolder: parentID) else { throw WorkspaceError.folderNotFound }
        try relocateFolder(id, parentID: parentID, projectID: projectID, placement: .end)
    }

    /// Puts a folder just before another, as its sibling (shares its
    /// parent), moving it (and its sessions) to that folder's project if
    /// need be. With no target it goes last at the project's top level.
    public mutating func moveFolder(_ id: UUID, before targetID: UUID?, inProject projectID: UUID) throws {
        guard id != targetID else { return }
        guard let targetID else {
            try relocateFolder(id, parentID: nil, projectID: projectID, placement: .end)
            return
        }
        guard let target = folder(targetID) else { throw WorkspaceError.folderNotFound }
        try relocateFolder(id, parentID: target.parentID, projectID: projectID, placement: .beforeSibling(targetID))
    }

    /// Puts a folder just after another, as its sibling.
    public mutating func moveFolder(_ id: UUID, after targetID: UUID, inProject projectID: UUID) throws {
        guard id != targetID else { return }
        guard let target = folder(targetID) else { throw WorkspaceError.folderNotFound }
        try relocateFolder(id, parentID: target.parentID, projectID: projectID, placement: .afterSibling(targetID))
    }

    /// Moves a project into another's place in the sidebar: just after it when
    /// dragged down, just before it when dragged up. So one drag can swap
    /// neighbours or make a project first or last.
    public mutating func moveProject(_ id: UUID, onto targetID: UUID) {
        guard id != targetID, let from = projects.firstIndex(where: { $0.id == id }),
              let to = projects.firstIndex(where: { $0.id == targetID }) else { return }
        projects.insert(projects.remove(at: from), at: to)
    }

    /// Archives the completed sessions in a group (a folder's whole subtree,
    /// not just its direct sessions). Returns how many were archived.
    @discardableResult
    public mutating func archiveCompleted(in group: SessionGroup) -> Int {
        let ids = sessionsInSubtree(group).filter { $0.status == .completed }.map(\.id)
        for id in ids { updateSession(id) { $0.isArchived = true } }
        return ids.count
    }

    /// Archives the completed sessions in a project, whichever folder they're
    /// in (or Unfiled). Returns the ids archived.
    @discardableResult
    public mutating func archiveCompleted(inProject projectID: UUID) -> [UUID] {
        let ids = sessions.filter { $0.projectID == projectID && $0.status == .completed && !$0.isArchived }.map(\.id)
        for id in ids { updateSession(id) { $0.isArchived = true } }
        return ids
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
            deletedClaudeSessionIDs.formUnion(ownedConversations(of: session))
            if let agentID = session.agentID { deletedAgentIDs.insert(agentID) }
        }
        removeSession(id)
    }

    /// Its conversations, less any replaced one another session has as its
    /// own (a copy's `/clear` once landed on its original).
    public func ownedConversations(of session: Session) -> [String] {
        let others = Set(sessions.filter { $0.id != session.id }.compactMap(\.claudeSessionID))
        return session.conversations.filter { $0 == session.claudeSessionID || !others.contains($0) }
    }

    /// Forgets deleted agents that `claude agents` no longer lists: `claude rm` has finished.
    public mutating func forgetDeletedAgents(notIn listed: Set<String>) {
        if !deletedAgentIDs.isSubset(of: listed) { deletedAgentIDs.formIntersection(listed) }
    }

    /// Whether a conversation or agent belongs to a removed or deleted
    /// session, so mustn't be imported again.
    public func isRemoved(claudeSessionID: String?, agentID: String? = nil) -> Bool {
        if let claudeSessionID, deletedClaudeSessionIDs.contains(claudeSessionID)
            || removedSessions.contains(where: { $0.session.claudeSessionID == claudeSessionID
                // A replaced one that's now another session's own is theirs.
                || ($0.session.replacedConversations.contains(claudeSessionID) && session(claudeSessionID: claudeSessionID) == nil) }) {
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

    public mutating func archive(_ id: UUID) {
        updateSession(id) { $0.isArchived = true }
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

    /// Sets a folder's `parentID` directly, bypassing the cycle guard every
    /// public move goes through. Only for testing decode-time sanitization
    /// against a state.json corrupted into a cycle.
    mutating func setParentIDForTesting(_ id: UUID, to parentID: UUID?) {
        guard let (p, f) = folderIndex(id) else { return }
        projects[p].folders[f].parentID = parentID
    }

    private mutating func detachFromFolders(_ sessionID: UUID) {
        for p in projects.indices {
            for f in projects[p].folders.indices {
                projects[p].folders[f].sessionIDs.removeAll { $0 == sessionID }
            }
        }
    }

    private func uniqueFolderName(in project: Project, parentID: UUID?) -> String {
        let existing = Set(project.folders.filter { $0.parentID == parentID }.map(\.name))
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
