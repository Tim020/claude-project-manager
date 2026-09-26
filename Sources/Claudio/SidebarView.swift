#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

/// Design 1a: source list with the full Project → Folder → Session tree.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    /// Current width (live while the divider is being dragged).
    let width: Double
    @Environment(\.presentNewSession) private var presentNewSession
    @Environment(\.addProject) private var addProject
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            filterField(text: $model.filterText)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sidebar) { project in
                            ProjectSection(project: project, now: context.date)
                        }
                        if model.workspace.projects.isEmpty {
                            emptyHint
                        } else if model.sidebar.isEmpty {
                            Text(noMatchesText)
                                .font(DS.font(12))
                                .foregroundStyle(DS.dim)
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                        }
                        recencyHint
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            }
            UsageSection(usage: model.usage)
            footer
        }
        .frame(width: width)
        .background(DS.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Room for the window's traffic lights.
            Spacer().frame(width: 64)
            Spacer()
            IconButton(systemName: "folder.badge.plus", help: "New Folder", size: 16) {
                if let project = currentProjectID { model.createFolder(in: project) }
            }
            .disabled(currentProjectID == nil)
            IconButton(systemName: "plus", help: "New Session", size: 16) {
                presentNewSession(model.selectedGroup)
            }
            .disabled(model.workspace.projects.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func filterField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
            TextField("Filter sessions", text: text)
                .textFieldStyle(.plain)
                .font(DS.font(13))
                .foregroundStyle(DS.text)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
            statusFilterMenu
        }
        .foregroundStyle(DS.dim)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .fieldChrome(background: DS.window)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No projects yet")
                .font(DS.font(13, .bold))
                .foregroundStyle(DS.text)
            Text("Import the projects you've used Claude Code in, or add a directory.")
                .font(DS.font(12))
                .foregroundStyle(DS.muted)
            HStack(spacing: 8) {
                Button("Import…") { commands.showImportProjects = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Add Project…") { addProject() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(8)
        .padding(.top, 10)
    }

    /// Status counts; click one to show only those sessions (again for all).
    private var footer: some View {
        let counts = model.footerStatusCounts
        return HStack(spacing: 6) {
            ForEach(SessionStatus.allCases, id: \.self) { status in
                let isActive = model.statusFilter == status
                Button { model.toggleStatusFilter(status) } label: {
                    HStack(spacing: 5) {
                        StatusDot(status: status, size: 7)
                        Text("\(counts[status]) \(status.label)")
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(isActive ? DS.color(for: status).opacity(0.25) : .clear))
                    .overlay(Capsule().stroke(isActive ? DS.color(for: status).opacity(0.7) : .clear, lineWidth: 1))
                    .foregroundStyle(isActive ? DS.text : DS.muted)
                    .opacity(model.statusFilter == nil || isActive ? 1 : 0.55)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(isActive ? "Show all sessions" : "Show only \(status.label) sessions")
            }
            Spacer(minLength: 0)
        }
        .font(DS.font(12))
        .lineLimit(1)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .overlay(alignment: .top) { HorizontalRule() }
    }

    /// Says how many sessions the recent-activity window hides, with a way
    /// to show them.
    @ViewBuilder private var recencyHint: some View {
        let hidden = model.hiddenByRecencyCount
        if hidden > 0 {
            let window = AppSettings.activityWindowLabel(days: model.settings.activityWindowDays).lowercased()
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                Text("\(hidden) \(hidden == 1 ? "session" : "sessions") not active in the \(window)")
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Show All") { model.setActivityWindow(days: 0) }
                    .buttonStyle(.link)
                    .help("Show every session, whatever its age. Change this in the filter menu or Settings.")
            }
            .font(DS.font(11.5))
            .foregroundStyle(DS.dim)
            .padding(.horizontal, 8)
            .padding(.top, 14)
        }
    }

    /// Status and recent-activity filters, at the end of the filter field.
    private var statusFilterMenu: some View {
        Menu {
            Button {
                model.statusFilter = nil
            } label: {
                if model.statusFilter == nil { Label("All Sessions", systemImage: "checkmark") } else { Text("All Sessions") }
            }
            Divider()
            ForEach(SessionStatus.allCases, id: \.self) { status in
                Button {
                    model.statusFilter = status
                } label: {
                    if model.statusFilter == status { Label(status.label, systemImage: "checkmark") } else { Text(status.label) }
                }
            }
            Section("Active Within") {
                let current = model.settings.activityWindowDays
                let choices = AppSettings.activityWindowPresets.contains(current)
                    ? AppSettings.activityWindowPresets
                    : (AppSettings.activityWindowPresets.dropLast() + [current, 0]).sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
                ForEach(choices, id: \.self) { days in
                    Button { model.setActivityWindow(days: days) } label: {
                        let label = AppSettings.activityWindowLabel(days: days)
                        if days == current { Label(label, systemImage: "checkmark") } else { Text(label) }
                    }
                }
                Button("Custom…") {
                    UserDefaults.standard.set(SettingsPane.general.rawValue, forKey: "settingsPane")
                    openSettings()
                }
            }
        } label: {
            Image(systemName: model.statusFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(model.statusFilter.map(DS.color(for:)) ?? DS.dim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.statusFilter.map { "Showing only \($0.label) sessions" } ?? "Filter by status or recent activity")
    }

    private var noMatchesText: String {
        switch (model.statusFilter, model.filterText.isEmpty) {
        case (nil, _): return "No sessions match “\(model.filterText)”"
        case (let status?, true): return "No \(status.label) sessions"
        case (let status?, false): return "No \(status.label) sessions match “\(model.filterText)”"
        }
    }

    private var currentProjectID: UUID? {
        model.selectedSession?.projectID ?? model.workspace.projects.first?.id
    }
}

private struct ProjectSection: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    @Environment(\.presentNewSession) private var presentNewSession
    let project: SidebarProject
    let now: Date
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(project.folders) { folder in
                FolderSection(folder: folder, projectID: project.id, now: now)
            }
        }
        .padding(.top, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: project.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 14)
            Text(project.name.uppercased())
                .font(DS.font(11, .extraBold))
                .kerning(0.66)
                .lineLimit(1)
                .help(project.path)
            Spacer(minLength: 4)
            Text(project.displayPath)
                .font(DS.font(11, .semibold))
                .foregroundStyle(DS.dim)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(-1)
                .help(project.path)
            StatusCountPills(counts: project.statusCounts)
        }
        .foregroundStyle(DS.muted)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(isDropTarget ? DS.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.toggleCollapsed(project.id) }
        .dropDestination(for: String.self) { items, _ in
            // Dropping on the project header files the session as Unfiled.
            moveSessions(items, to: .unfiled(projectID: project.id))
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            Button("New Session…") { presentNewSession(.unfiled(projectID: project.id)) }
            Button("New Folder") { model.createFolder(in: project.id) }
            Divider()
            Button("Refresh Sessions") { Task { await model.refreshAll() } }
            Button("Import Claude Code Projects…") { commands.showImportProjects = true }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            }
            Divider()
            Button("Remove Project", role: .destructive) { model.removeProject(project.id) }
        }
    }

    private func moveSessions(_ items: [String], to group: SessionGroup) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:))
        ids.forEach { model.moveSession($0, to: group) }
        return !ids.isEmpty
    }
}

/// One pill per state with sessions in it (working, awaiting input,
/// completed), coloured like the status dots, for a project header.
private struct StatusCountPills: View {
    let counts: StatusCounts

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SessionStatus.allCases, id: \.self) { status in
                let count = counts[status]
                if count > 0 {
                    Text("\(count)")
                        .font(DS.font(10.5, .bold))
                        .monospacedDigit()
                        .foregroundStyle(status == .completed ? DS.muted : DS.color(for: status))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 16)
                        .background(Capsule().fill(DS.color(for: status).opacity(status == .completed ? 0.18 : 0.22)))
                        .help("\(count) \(status.label)")
                }
            }
        }
        .fixedSize()
    }
}

/// Leading offsets for the tree's levels, so each level sits inside its
/// parent: a project's name starts at 28pt (8 padding + 14 chevron + 6
/// spacing), and folders start just inside that.
enum SidebarIndent {
    static let folder: CGFloat = 22
    /// A session's status dot sits just before its folder's name, which starts
    /// at folder + chevron (8) + spacing (7) + icon (16) + spacing (7).
    static let session: CGFloat = folder + 8 + 7 + 16 + 7 - 6
}

private struct FolderSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentNewSession) private var presentNewSession
    let folder: SidebarFolder
    let projectID: UUID
    let now: Date
    @State private var isDropTarget = false

    private var folderID: UUID? {
        if case .folder(let id) = folder.group { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let folderID, model.renamingFolderID == folderID {
                FolderRenameField(folderID: folderID, initialName: folder.name)
            } else {
                row
            }
            ForEach(folder.sessions) { session in
                SessionRow(session: session, now: now)
            }
        }
        .padding(.top, 2)
    }

    private var row: some View {
        HStack(spacing: 7) {
            Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DS.dim)
                .frame(width: 8)
            Image(systemName: folder.isUnfiled ? "tray" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(folder.isUnfiled ? DS.dim : DS.blue)
                .frame(width: 16)
            Text(folder.name)
                .font(DS.font(13.5, .bold, italic: folder.isUnfiled))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            StatusCountPills(counts: folder.statusCounts)
        }
        .padding(.vertical, 5)
        .padding(.leading, SidebarIndent.folder)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(isDropTarget ? DS.selection : .clear))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isDropTarget ? DS.blue : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let folderID { model.beginRenaming(folderID: folderID) }
        }
        .onTapGesture { model.toggleCollapsed(folder.group) }
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            ids.forEach { model.moveSession($0, to: folder.group) }
            return !ids.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .contextMenu { FolderMenu(group: folder.group, projectID: projectID) }
    }
}

/// Context menu for a folder, as specified in design 1c.
struct FolderMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentNewSession) private var presentNewSession
    let group: SessionGroup
    let projectID: UUID

    var body: some View {
        if case .folder(let folderID) = group {
            Button("Rename Folder…") { model.beginRenaming(folderID: folderID) }
            Button("New Session in Folder…") { presentNewSession(group) }
            let others = model.workspace.projects.filter { $0.id != projectID }
            Menu("Move to Project") {
                ForEach(others) { project in
                    Button(project.name) { model.moveFolder(folderID, toProject: project.id) }
                }
            }
            .disabled(others.isEmpty)
            Divider()
            Button("Archive Completed") { model.archiveCompleted(in: group) }
            Button("Delete Folder", role: .destructive) { model.deleteFolder(folderID) }
        } else {
            Button("New Session…") { presentNewSession(group) }
            Button("New Folder") { model.createFolder(in: projectID) }
            Divider()
            Button("Archive Completed") { model.archiveCompleted(in: group) }
        }
    }
}

/// Inline folder rename: blue-bordered field with a caret, as in design 1a.
private struct FolderRenameField: View {
    @Environment(AppModel.self) private var model
    let folderID: UUID
    let initialName: String
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(DS.blue)
                .frame(width: 16)
            TextField("Folder name", text: $name)
                .textFieldStyle(.plain)
                .font(DS.font(13.5))
                .foregroundStyle(DS.text)
                .focused($focused)
                .onSubmit { model.commitRename(folderID: folderID, name: name) }
                .onExitCommand { model.cancelRename() }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .fieldChrome(background: DS.window, border: DS.blue)
        .padding(.leading, SidebarIndent.folder)
        .padding(.top, 4)
        .onAppear {
            name = initialName
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && model.renamingFolderID == folderID {
                model.commitRename(folderID: folderID, name: name)
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let now: Date
    @State private var hovering = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var isDropTarget = false

    private var isSelected: Bool { model.selectedSessionID == session.id }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: session.status)
                .help(SessionIndicators.statusHelp(session))
            Text(session.name)
                .font(DS.font(13.5))
                .foregroundStyle(session.status == .completed && !isSelected ? DS.muted : DS.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(session.needsAction ?? (session.summary.isEmpty ? session.name : session.summary))
            Spacer(minLength: 4)
            ForEach(SessionIndicators.indicators(for: session, isOpenInTerminal: model.isOpenInTerminal(session.id)), id: \.symbol) { indicator in
                HStack(spacing: 2) {
                    Image(systemName: indicator.symbol)
                        .font(.system(size: 10))
                    if let text = indicator.text {
                        Text(text).font(DS.font(10.5, .semibold))
                    }
                }
                .foregroundStyle(DS.dim)
                .help(indicator.help)
            }
            Text(RelativeAge.string(from: session.lastActivity, now: now))
                .font(DS.font(11))
                .foregroundStyle(DS.muted)
                .help("Last active \(session.lastActivity.formatted(date: .abbreviated, time: .shortened))")
        }
        .padding(.vertical, 5)
        .padding(.leading, SidebarIndent.session)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? DS.selection : (hovering ? Color.white.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(session.id) }
        .draggable(session.id.uuidString) {
            HStack(spacing: 6) {
                StatusDot(status: session.status)
                Text(session.name).font(DS.font(13)).foregroundStyle(DS.text)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(DS.input))
        }
        // Drop another session here to put it just above this one.
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:)).filter { $0 != session.id }
            ids.forEach { model.moveSession($0, before: session.id) }
            return !ids.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle().fill(DS.blue).frame(height: 2).padding(.leading, SidebarIndent.session - 8).offset(y: -1)
            }
        }
        .contextMenu { SessionMenu(session: session, renaming: $renaming, newName: $newName, confirmDelete: $confirmDelete) }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.renameSession(session.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .deleteSessionConfirmation(session: session, isPresented: $confirmDelete)
    }
}

/// Actions for a session, shared by the sidebar row and the detail header.
struct SessionMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @Binding var renaming: Bool
    @Binding var newName: String
    @Binding var confirmDelete: Bool

    var body: some View {
        Button("Rename…") {
            newName = session.name
            renaming = true
        }
        Menu("Role") {
            RoleMenuItems(session: session)
        }
        Menu("Move to Folder") {
            if let project = model.workspace.project(session.projectID) {
                ForEach(project.folders) { folder in
                    Button(folder.name) { model.moveSession(session.id, to: .folder(folder.id)) }
                }
                if !project.folders.isEmpty { Divider() }
                Button(Workspace.unfiledName) { model.moveSession(session.id, to: .unfiled(projectID: project.id)) }
                Button("New Folder") { model.createFolder(in: project.id, containing: session.id) }
            }
        }
        if !session.pullRequestURLs.isEmpty {
            Menu("Open Pull Request") {
                ForEach(session.pullRequestURLs, id: \.self) { url in
                    Button(PullRequestDetector.number(from: url).map { "#\($0)" } ?? url) {
                        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                    }
                }
            }
        }
        Divider()
        if model.isRunning(session.id) || model.isAgentAlive(session.id) {
            Button("Stop Session") { model.stop(session.id) }
        } else {
            Button(session.hasConversation ? "Resume Session" : "Start Session") {
                model.select(session.id)
                model.resume(session.id)
            }
        }
        Button("Delete Session…", role: .destructive) { confirmDelete = true }
    }
}
extension View {
    /// Confirms deleting a session, from Claudio only or from Claude Code
    /// too (`claude rm` for a background agent, plus its history files).
    func deleteSessionConfirmation(session: Session, isPresented: Binding<Bool>) -> some View {
        modifier(DeleteSessionConfirmation(session: session, isPresented: isPresented))
    }
}

private struct DeleteSessionConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let session: Session
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete “\(session.name)”?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Remove from Claudio") { model.deleteSession(session.id, .claudioOnly) }
            Button("Remove from Claude Code and Claudio", role: .destructive) { model.deleteSession(session.id, .everywhere) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if session.agentID != nil {
                Text("Remove from Claudio leaves the background agent and its history in Claude Code. Removing it from Claude Code too runs `claude rm`, which also removes its worktree when that's safe, and deletes its history. This can't be undone.")
            } else {
                Text("Remove from Claudio leaves the conversation's history in Claude Code. Removing it from Claude Code too deletes that history. This can't be undone.")
            }
        }
    }
}
/// Plan usage from Claude Code (5-hour session and weekly limits), as
/// reported to the status line of sessions Claudio launched.
private struct UsageSection: View {
    let usage: UsageSnapshot?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("PLAN USAGE")
                        .font(DS.font(10.5, .extraBold))
                        .kerning(0.6)
                        .foregroundStyle(DS.dim)
                    Spacer()
                    if let plan = usage?.subscriptionType {
                        Text(plan.capitalized)
                            .font(DS.font(11, .semibold))
                            .foregroundStyle(DS.dim)
                    }
                }
                if let usage, usage.fiveHour != nil || usage.sevenDay != nil {
                    if let window = usage.fiveHour { row("Session", window, now: context.date) }
                    if let window = usage.sevenDay { row("Week", window, now: context.date) }
                } else {
                    Text("Checking plan usage… (needs a Claude plan sign-in)")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { HorizontalRule() }
            .help(usage.map { "Updated \(RelativeAge.string(from: $0.updatedAt, now: context.date)) ago" } ?? "")
        }
    }

    private func row(_ title: String, _ window: UsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(DS.font(12, .semibold))
                    .foregroundStyle(DS.muted)
                Spacer(minLength: 4)
                Text(window.percentLabel)
                    .font(DS.font(12, .bold))
                    .foregroundStyle(color(window))
                Text(window.resetLabel(now: now))
                    .font(DS.font(11))
                    .foregroundStyle(DS.dim)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.border)
                    Capsule().fill(color(window)).frame(width: geometry.size.width * window.fraction)
                }
            }
            .frame(height: 4)
        }
    }

    private func color(_ window: UsageWindow) -> Color {
        switch window.usedPercentage {
        case ..<70: return DS.teal
        case ..<90: return DS.orange
        default: return DS.red
        }
    }
}
#endif
