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

/// Owns the live terminals (in the UI layer) so the model can stop them.
@MainActor
public protocol TerminalControlling: AnyObject {
    func terminate(_ sessionID: UUID)
}

/// App state and every user action. The SwiftUI layer is a thin view over this.
///
/// Each running session is an interactive `claude` in a terminal. The model
/// hands out a `TerminalLaunch` for the UI to start, learns about progress
/// from Claude Code hook events, and is told when the terminal exits.
@MainActor
@Observable
public final class AppModel {
    public private(set) var state: PersistedState
    public var selectedSessionID: UUID?
    public var filterText = ""
    public var renamingFolderID: UUID?
    /// A user-facing error to show in an alert; the view clears it.
    public var errorMessage: String?
    private var running: Set<UUID> = []
    @ObservationIgnored private var pendingLaunches: [UUID: TerminalLaunch] = [:]
    private var exitCodes: [UUID: Int32] = [:]
    @ObservationIgnored private var histories: [UUID: [TranscriptLine]] = [:]

    @ObservationIgnored public weak var terminals: TerminalControlling?
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let discovery: SessionDiscovery
    @ObservationIgnored private let hookEventsURL: URL
    @ObservationIgnored private var hookTailer: HookEventTailer
    @ObservationIgnored private let locateClaude: (String?) -> String?
    @ObservationIgnored private let shell: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored public let home: String

    public init(
        store: StateStore,
        discovery: SessionDiscovery,
        hookEventsURL: URL,
        locateClaude: @escaping (String?) -> String? = { ClaudeExecutableLocator.locate(override: $0) },
        shell: String = ClaudeExecutableLocator.defaultShell(),
        now: @escaping () -> Date = Date.init,
        home: String = NSHomeDirectory()
    ) {
        self.store = store
        self.discovery = discovery
        self.hookEventsURL = hookEventsURL
        self.hookTailer = HookEventTailer(url: hookEventsURL, startAtEnd: true)
        self.locateClaude = locateClaude
        self.shell = shell
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

    public func isRunning(_ sessionID: UUID) -> Bool {
        running.contains(sessionID)
    }

    /// Exit code of the session's last terminal, if it has exited since it was started.
    public func lastExitCode(_ sessionID: UUID) -> Int32? {
        exitCodes[sessionID]
    }

    /// Read-only transcript from Claude Code's history file, for sessions that
    /// aren't running.
    public func history(for sessionID: UUID) -> [TranscriptLine] {
        if let cached = histories[sessionID] { return cached }
        guard let session = state.workspace.session(sessionID) else { return [] }
        var builder = TranscriptBuilder(workingDirectory: session.workingDirectory)
        if session.hasConversation, let claudeID = session.claudeSessionID,
           let events = try? discovery.loadHistory(projectPath: session.workingDirectory, claudeSessionID: claudeID) {
            events.forEach { builder.apply($0) }
        }
        histories[sessionID] = builder.lines
        return builder.lines
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
        ids.forEach(stop)
        if let selected = selectedSessionID, ids.contains(selected) { selectedSessionID = nil }
        state.workspace.removeProject(id)
        save()
    }

    public func toggleCollapsed(_ projectID: UUID) {
        state.workspace.toggleCollapsed(projectID)
        save()
    }

    /// Re-reads every project's sessions from disk (e.g. ones run in another terminal).
    public func refreshAll() {
        for project in state.workspace.projects { importSessions(for: project.id) }
        histories.removeAll()
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
        stop(id)
        exitCodes[id] = nil
        histories[id] = nil
        state.workspace.removeSession(id)
        save()
    }

    /// Adds a session, selects it and opens its terminal (with the prompt, if any).
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
        select(session.id)
        save()
        start(session.id, prompt: prompt)
        return session.id
    }

    /// Queues a terminal launch for the session (new or `--resume`). Returns
    /// false if it is already running or `claude` can't be found.
    @discardableResult
    public func start(_ sessionID: UUID, prompt: String? = nil) -> Bool {
        guard !running.contains(sessionID), let session = state.workspace.session(sessionID) else { return false }
        guard let executable = locateClaude(state.settings.claudePath) else {
            errorMessage = "Claude Code CLI not found. Install it, or set its location in Settings."
            return false
        }
        try? FileManager.default.createDirectory(at: hookEventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        pendingLaunches[sessionID] = TerminalLaunch.make(session: session, claudeExecutable: executable, shell: shell,
                                                         initialPrompt: prompt, hookEventsPath: hookEventsURL.path)
        running.insert(sessionID)
        exitCodes[sessionID] = nil
        return true
    }

    /// Hands the queued launch to the terminal that will run it (once).
    public func takePendingLaunch(_ sessionID: UUID) -> TerminalLaunch? {
        pendingLaunches.removeValue(forKey: sessionID)
    }

    /// Called by the UI when a session's terminal process exits.
    public func terminalExited(_ sessionID: UUID, exitCode: Int32?) {
        running.remove(sessionID)
        pendingLaunches[sessionID] = nil
        exitCodes[sessionID] = exitCode ?? 0
        histories[sessionID] = nil
        state.workspace.updateSession(sessionID) { session in
            if session.status == .working { session.status = .completed }
        }
        save()
    }

    public func stop(_ sessionID: UUID) {
        let wasRunning = running.remove(sessionID) != nil
        pendingLaunches[sessionID] = nil
        if wasRunning { terminals?.terminate(sessionID) }
    }

    public func shutdown() {
        Array(running).forEach(stop)
        save()
    }

    /// Applies hook events written since the last poll.
    public func pollHookEvents() {
        let events = hookTailer.readNew()
        guard !events.isEmpty else { return }
        var changed = false
        for event in events where state.workspace.session(event.appSessionID) != nil {
            state.workspace.updateSession(event.appSessionID) { HookReducer.apply(event, to: &$0, now: now()) }
            if event.name == .stop { histories[event.appSessionID] = nil }
            changed = true
        }
        if changed { save() }
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

    // MARK: - Helpers

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
