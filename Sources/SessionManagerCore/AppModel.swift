import Foundation
import Observation

public struct NewSessionRequest: Equatable, Sendable {
    public var projectID: UUID
    /// Folder to create the session in; Unfiled when nil.
    public var folderID: UUID?
    public var name: String
    public var role: SessionRole
    public var prompt: String
    public var model: String?
    public var permissionMode: PermissionMode

    public init(projectID: UUID, folderID: UUID?, name: String, role: SessionRole, prompt: String, model: String?, permissionMode: PermissionMode) {
        self.projectID = projectID
        self.folderID = folderID
        self.name = name
        self.role = role
        self.prompt = prompt
        self.model = model
        self.permissionMode = permissionMode
    }
}

public struct Breadcrumb: Equatable, Sendable {
    public var project: String
    public var folder: String
    public var session: String
}

/// App state and every user action. The SwiftUI layer is a thin view over this.
@MainActor
@Observable
public final class AppModel {
    public private(set) var state: PersistedState
    public var selectedSessionID: UUID?
    public var filterText = ""
    public var renamingFolderID: UUID?
    /// A user-facing error to show in an alert; the view clears it.
    public var errorMessage: String?
    public private(set) var activities: [UUID: SessionActivity] = [:]
    private var running: Set<UUID> = []

    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let discovery: SessionDiscovery
    @ObservationIgnored private let processFactory: (ClaudeLaunchConfiguration) -> AgentProcess
    @ObservationIgnored private let locateClaude: (String?) -> String?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored public let home: String
    @ObservationIgnored private var processes: [UUID: AgentProcess] = [:]

    public init(
        store: StateStore,
        discovery: SessionDiscovery,
        processFactory: @escaping (ClaudeLaunchConfiguration) -> AgentProcess,
        locateClaude: @escaping (String?) -> String? = { ClaudeExecutableLocator.locate(override: $0) },
        now: @escaping () -> Date = Date.init,
        home: String = NSHomeDirectory()
    ) {
        self.store = store
        self.discovery = discovery
        self.processFactory = processFactory
        self.locateClaude = locateClaude
        self.now = now
        self.home = home
        do {
            state = try store.load()
        } catch {
            state = PersistedState()
            errorMessage = "Couldn't load saved sessions: \(AppModel.describe(error))"
        }
        // Nothing is running at launch, whatever was saved.
        for session in state.workspace.sessions where session.status == .working {
            state.workspace.updateSession(session.id) { $0.status = .completed }
        }
    }

    // MARK: - Derived state

    public var workspace: Workspace { state.workspace }
    public var settings: AppSettings { state.settings }

    public var sidebar: [SidebarProject] {
        Sidebar.build(state.workspace, filter: filterText, home: home)
    }

    public var selectedSession: Session? {
        selectedSessionID.flatMap { state.workspace.session($0) }
    }

    public var selectedGroup: SessionGroup? {
        selectedSessionID.flatMap { state.workspace.group(of: $0) }
    }

    /// The selected session's folder siblings, shown as tabs or split panes.
    public var tabs: [Session] {
        guard let group = selectedGroup else { return [] }
        return state.workspace.sessions(in: group)
    }

    public var breadcrumb: Breadcrumb? {
        guard let session = selectedSession, let group = selectedGroup else { return nil }
        return Breadcrumb(project: state.workspace.project(session.projectID)?.name ?? "",
                          folder: state.workspace.name(of: group),
                          session: session.name)
    }

    public var statusCounts: StatusCounts { state.workspace.statusCounts() }

    public var awaitingInputCount: Int { statusCounts.awaitingInput }

    public func activity(for sessionID: UUID) -> SessionActivity {
        activities[sessionID] ?? SessionActivity(workingDirectory: state.workspace.session(sessionID)?.workingDirectory ?? "/")
    }

    public func isRunning(_ sessionID: UUID) -> Bool {
        running.contains(sessionID)
    }

    // MARK: - Projects

    @discardableResult
    public func addProject(path: String) -> UUID {
        let id = state.workspace.addProject(path: path)
        importSessions(for: id)
        save()
        return id
    }

    public func removeProject(_ id: UUID) {
        let ids = state.workspace.sessions.filter { $0.projectID == id }.map(\.id)
        ids.forEach(stopProcess)
        if let selected = selectedSessionID, ids.contains(selected) { selectedSessionID = nil }
        ids.forEach { activities[$0] = nil }
        state.workspace.removeProject(id)
        save()
    }

    public func toggleCollapsed(_ projectID: UUID) {
        state.workspace.toggleCollapsed(projectID)
        save()
    }

    /// Re-reads every project's sessions from disk (e.g. ones run in a terminal).
    public func refreshAll() {
        for project in state.workspace.projects { importSessions(for: project.id) }
        save()
    }

    private func importSessions(for projectID: UUID) {
        guard let project = state.workspace.project(projectID) else { return }
        do {
            let found = try discovery.discover(projectPath: project.path)
            state.workspace.importDiscovered(found, into: projectID, skipping: running)
        } catch {
            errorMessage = "Couldn't read Claude Code sessions for \(project.name): \(AppModel.describe(error))"
        }
    }

    // MARK: - Folders

    /// Creates a folder (optionally holding a dropped session) and starts inline rename.
    @discardableResult
    public func createFolder(in projectID: UUID, containing sessionID: UUID? = nil) -> UUID? {
        guard let id = attempt({ try state.workspace.createFolder(in: projectID, named: "", containing: sessionID) }) else { return nil }
        if state.workspace.project(projectID)?.isCollapsed == true { state.workspace.toggleCollapsed(projectID) }
        renamingFolderID = id
        save()
        return id
    }

    public func beginRenaming(folderID: UUID) {
        renamingFolderID = folderID
    }

    /// Applies an inline rename; a blank name leaves the folder as it was.
    public func commitRename(folderID: UUID, name: String) {
        renamingFolderID = nil
        guard Workspace.trimmed(name) != nil else { return }
        attempt { try state.workspace.renameFolder(folderID, to: name) }
        save()
    }

    public func cancelRename() {
        renamingFolderID = nil
    }

    public func deleteFolder(_ id: UUID) {
        state.workspace.deleteFolder(id)
        save()
    }

    public func moveFolder(_ id: UUID, toProject projectID: UUID) {
        attempt { try state.workspace.moveFolder(id, toProject: projectID) }
        save()
    }

    public func archiveCompleted(in group: SessionGroup) {
        state.workspace.archiveCompleted(in: group)
        if let selected = selectedSessionID, state.workspace.session(selected)?.isArchived == true {
            selectedSessionID = tabs.first?.id
        }
        save()
    }

    // MARK: - Sessions

    public func select(_ sessionID: UUID?) {
        selectedSessionID = sessionID
        guard let sessionID, let group = state.workspace.group(of: sessionID) else { return }
        for sibling in state.workspace.sessions(in: group) { loadHistoryIfNeeded(sibling.id) }
    }

    public func moveSession(_ id: UUID, to group: SessionGroup, at index: Int? = nil) {
        attempt { try state.workspace.moveSession(id, to: group, at: index) }
        save()
    }

    public func renameSession(_ id: UUID, to name: String) {
        attempt { try state.workspace.renameSession(id, to: name) }
        save()
    }

    public func deleteSession(_ id: UUID) {
        if selectedSessionID == id {
            let siblings = tabs
            let index = siblings.firstIndex { $0.id == id } ?? 0
            let remaining = siblings.filter { $0.id != id }
            selectedSessionID = remaining.isEmpty ? nil : remaining[max(0, min(index - 1, remaining.count - 1))].id
        }
        stopProcess(id)
        activities[id] = nil
        state.workspace.removeSession(id)
        save()
    }

    /// Adds a session, selects it and, if there's a prompt, starts Claude Code.
    @discardableResult
    public func createSession(_ request: NewSessionRequest) -> UUID? {
        guard let project = state.workspace.project(request.projectID) else { return nil }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = Workspace.trimmed(request.name)
            ?? SessionDiscovery.truncateAtWord(TranscriptBuilder.firstLine(prompt), to: SessionDiscovery.maxTitleLength)
        let session = Session(projectID: project.id,
                              claudeSessionID: UUID().uuidString.lowercased(),
                              name: name.isEmpty ? "New session" : name,
                              role: request.role,
                              workingDirectory: project.path,
                              model: request.model ?? state.settings.defaultModel,
                              permissionMode: request.permissionMode,
                              createdAt: now())
        guard attempt({ try state.workspace.addSession(session, toFolder: request.folderID) }) != nil else { return nil }
        activities[session.id] = SessionActivity(workingDirectory: session.workingDirectory)
        select(session.id)
        save()
        if !prompt.isEmpty { send(prompt, to: session.id) }
        return session.id
    }

    public func send(_ message: String, to sessionID: UUID) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state.workspace.session(sessionID) != nil else { return }
        loadHistoryIfNeeded(sessionID)
        guard let process = ensureProcess(for: sessionID) else { return }
        do {
            try process.send(StreamInput.userMessage(text))
        } catch {
            errorMessage = "Couldn't send the message: \(AppModel.describe(error))"
            return
        }
        mutate(sessionID) { session, activity in
            SessionReducer.promptSent(to: &session, activity: &activity, now: now(), prompt: text)
        }
        save()
    }

    public func interrupt(_ sessionID: UUID) {
        guard let process = processes[sessionID], let line = try? StreamInput.interrupt() else { return }
        try? process.send(line)
    }

    public func stop(_ sessionID: UUID) {
        stopProcess(sessionID)
    }

    public func shutdown() {
        Array(processes.keys).forEach(stopProcess)
        save()
    }

    // MARK: - Settings

    public func setLayout(_ layout: LayoutMode) {
        state.settings.layout = layout
        save()
    }

    public func updateSettings(_ settings: AppSettings) {
        state.settings = settings
        save()
    }

    // MARK: - Process plumbing

    private func ensureProcess(for sessionID: UUID) -> AgentProcess? {
        if let existing = processes[sessionID], existing.isRunning { return existing }
        guard let session = state.workspace.session(sessionID) else { return nil }
        guard let executable = locateClaude(state.settings.claudePath) else {
            errorMessage = "Claude Code CLI not found. Install it, or set its location in Settings."
            return nil
        }
        let process = processFactory(ClaudeLaunchConfiguration(session: session, executable: executable))
        process.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, for: sessionID) }
        }
        process.onExit = { [weak self, weak process] code, stderr in
            MainActor.assumeIsolated { self?.handleExit(code: code, stderr: stderr, for: sessionID, process: process) }
        }
        do {
            try process.start()
        } catch {
            errorMessage = AppModel.describe(error)
            return nil
        }
        processes[sessionID] = process
        running.insert(sessionID)
        return process
    }

    private func stopProcess(_ sessionID: UUID) {
        guard let process = processes.removeValue(forKey: sessionID) else { return }
        running.remove(sessionID)
        process.terminate()
    }

    private func handle(_ event: StreamEvent, for sessionID: UUID) {
        guard state.workspace.session(sessionID) != nil else { return }
        mutate(sessionID) { session, activity in
            SessionReducer.apply(event, to: &session, activity: &activity, now: now())
        }
        switch event {
        case .initialized, .postTurnSummary, .result: save()
        default: break
        }
    }

    private func handleExit(code: Int32, stderr: String, for sessionID: UUID, process: AgentProcess?) {
        if let process, processes[sessionID] === process {
            processes[sessionID] = nil
            running.remove(sessionID)
        }
        guard state.workspace.session(sessionID) != nil else { return }
        mutate(sessionID) { session, activity in
            let wasActive = activity.isTurnActive
            SessionReducer.processExited(session: &session, activity: &activity, exitCode: code, now: now())
            let lastLine = stderr.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if wasActive && code != 0 && !lastLine.isEmpty { activity.transcript.appendError(lastLine) }
        }
        save()
    }

    private func loadHistoryIfNeeded(_ sessionID: UUID) {
        guard activities[sessionID] == nil, let session = state.workspace.session(sessionID) else { return }
        var activity = SessionActivity(workingDirectory: session.workingDirectory)
        if session.hasConversation, let claudeID = session.claudeSessionID,
           let events = try? discovery.loadHistory(projectPath: session.workingDirectory, claudeSessionID: claudeID) {
            events.forEach { activity.transcript.apply($0) }
        }
        activities[sessionID] = activity
    }

    private func mutate(_ sessionID: UUID, _ body: (inout Session, inout SessionActivity) -> Void) {
        var activity = activities[sessionID] ?? SessionActivity(workingDirectory: state.workspace.session(sessionID)?.workingDirectory ?? "/")
        state.workspace.updateSession(sessionID) { session in body(&session, &activity) }
        activities[sessionID] = activity
    }

    @discardableResult
    private func attempt<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            errorMessage = AppModel.describe(error)
            return nil
        }
    }

    private func save() {
        do {
            try store.save(state)
        } catch {
            errorMessage = "Couldn't save: \(AppModel.describe(error))"
        }
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .emptyName: return "Names can't be empty."
            case .projectNotFound: return "That project no longer exists."
            case .folderNotFound: return "That folder no longer exists."
            case .sessionNotFound: return "That session no longer exists."
            case .folderNotInProject: return "That folder belongs to a different project."
            }
        }
        return String(describing: error)
    }
}
