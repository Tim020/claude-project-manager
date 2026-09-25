#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

/// Design 1a: source list with the full Project → Folder → Session tree.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    @Environment(\.presentNewSession) private var presentNewSession
    @Environment(\.addProject) private var addProject

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
                            Text("No sessions match “\(model.filterText)”")
                                .font(DS.font(12))
                                .foregroundStyle(DS.dim)
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            }
            footer
        }
        .frame(minWidth: 290, maxWidth: 290)
        .fixedSize(horizontal: true, vertical: false)
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
            }
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

    private var footer: some View {
        let counts = model.statusCounts
        return HStack(spacing: 14) {
            ForEach(SessionStatus.allCases, id: \.self) { status in
                HStack(spacing: 5) {
                    StatusDot(status: status, size: 7)
                    Text("\(counts[status]) \(status.label)")
                }
            }
            Spacer(minLength: 0)
        }
        .font(DS.font(12))
        .foregroundStyle(DS.muted)
        .lineLimit(1)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .overlay(alignment: .top) { HorizontalRule() }
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
            Spacer(minLength: 4)
            Text(project.displayPath)
                .font(DS.font(11, .semibold))
                .foregroundStyle(DS.dim)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(DS.muted)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(isDropTarget ? DS.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.toggleCollapsed(project.id) }
        .help(project.path)
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
            Text("\(folder.sessions.count)")
                .font(DS.font(11, .semibold))
                .foregroundStyle(DS.dim)
        }
        .padding(.vertical, 5)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(isDropTarget ? DS.selection : .clear))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isDropTarget ? DS.blue : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let folderID { model.beginRenaming(folderID: folderID) }
        }
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
        .padding(.leading, 14)
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

    private var isSelected: Bool { model.selectedSessionID == session.id }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: session.status)
            Text(session.name)
                .font(DS.font(13.5))
                .foregroundStyle(session.status == .completed && !isSelected ? DS.muted : DS.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if model.isOpenInTerminal(session.id) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.dim)
                    .help("Running in a terminal")
            }
            if Worktree.name(ofPath: session.workingDirectory) != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.dim)
                    .help("Runs in its own git worktree")
            }
            Text(RelativeAge.string(from: session.lastActivity, now: now))
                .font(DS.font(11))
                .foregroundStyle(DS.muted)
        }
        .padding(.vertical, 5)
        .padding(.leading, 38)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? DS.selection : (hovering ? Color.white.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(session.id) }
        .help(session.needsAction ?? session.summary)
        .draggable(session.id.uuidString) {
            HStack(spacing: 6) {
                StatusDot(status: session.status)
                Text(session.name).font(DS.font(13)).foregroundStyle(DS.text)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(DS.input))
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
    /// Confirms deleting a session; for a background agent this also runs
    /// `claude rm`, which removes its worktree when that's safe.
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
            Button("Delete Session", role: .destructive) { model.deleteSession(session.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if session.agentID != nil {
                Text("The background agent is removed with `claude rm`, along with its worktree when that's safe.")
            } else {
                Text("The session is removed from Claudio. Its Claude Code history stays on disk.")
            }
        }
    }
}
#endif
