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
    /// Give a background agent its own git worktree (when the project is a git repo).
    public var useWorktree = true

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
/// Sessions normally run as Claude Code background agents (`claude --bg`,
/// optionally in their own worktree); a tab is a terminal running
/// `claude attach <id>`, so closing it only detaches. With background agents
/// off, a tab runs an interactive `claude` directly. The model hands out a
/// `TerminalLaunch` for the UI to start, learns about progress from
/// `claude agents --json` and hook events, and is told when a terminal exits.
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
    /// Most recently selected first; decides which tabs get split panes.
    private var recentSessionIDs: [UUID] = []
    /// Latest `claude agents` listing, by agent id.
    private var agents: [String: BackgroundAgent] = [:]
    /// Agent state last applied per agent, so polling doesn't clobber newer
    /// hook updates with an unchanged state.
    @ObservationIgnored private var appliedAgentStates: [String: String] = [:]
    /// The most recent background CLI operation (awaited by tests).
    @ObservationIgnored public private(set) var lastTask: Task<Void, Never>?

    @ObservationIgnored public weak var terminals: TerminalControlling?
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let discovery: SessionDiscovery
    @ObservationIgnored private let hookEventsURL: URL
    @ObservationIgnored private var hookTailer: HookEventTailer
    @ObservationIgnored private let runner: CommandRunning
    @ObservationIgnored private let locateClaude: (String?) -> String?
    @ObservationIgnored private let isGitRepository: (String) -> Bool
    @ObservationIgnored private let shell: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored public let home: String

    public init(
        store: StateStore,
        discovery: SessionDiscovery,
        hookEventsURL: URL,
        runner: CommandRunning = ProcessCommandRunner(),
        locateClaude: @escaping (String?) -> String? = { ClaudeExecutableLocator.locate(override: $0) },
        isGitRepository: @escaping (String) -> Bool = Worktree.isGitRepository,
        shell: String = ClaudeExecutableLocator.defaultShell(),
        now: @escaping () -> Date = Date.init,
        home: String = NSHomeDirectory()
    ) {
        self.store = store
        self.discovery = discovery
        self.hookEventsURL = hookEventsURL
        self.hookTailer = HookEventTailer(url: hookEventsURL, startAtEnd: true)
        self.runner = runner
        self.locateClaude = locateClaude
        self.isGitRepository = isGitRepository
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

    /// Open tabs in the selected session's folder.
    public var tabs: [Session] {
        guard let group = selectedGroup else { return [] }
        return state.workspace.openSessions(in: group)
    }

    /// Sessions in the selected folder whose tabs are closed (to reopen).
    public var closedTabs: [Session] {
        guard let group = selectedGroup else { return [] }
        return state.workspace.sessions(in: group).filter { !state.workspace.isOpen($0.id) }
    }

    /// Split view is for a real folder with more than one open tab; Unfiled
    /// is a catch-all, so it always uses tabs.
    public var canSplit: Bool {
        guard case .folder? = selectedGroup else { return false }
        return tabs.count > 1
    }

    /// The open tabs to show side by side, given how many panes fit.
    public func splitPanes(capacity: Int) -> [Session] {
        let open = tabs
        let ids = SplitLayout.panes(open: open.map(\.id), selected: selectedSessionID, recent: recentSessionIDs, capacity: capacity)
        return open.filter { ids.contains($0.id) }
    }

    public var breadcrumb: Breadcrumb? {
        guard let session = selectedSession, let group = selectedGroup else { return nil }
        return Breadcrumb(project: state.workspace.project(session.projectID)?.name ?? "",
                          folder: state.workspace.name(of: group),
                          session: session.name)
    }

    public var statusCounts: StatusCounts { state.workspace.statusCounts() }

    public var awaitingInputCount: Int { statusCounts.awaitingInput }

    /// Whether the session has a live terminal in the app.
    public func isRunning(_ sessionID: UUID) -> Bool {
        running.contains(sessionID)
    }

    /// Whether the session's background agent process is alive (it may be
    /// running without a terminal attached).
    public func isAgentAlive(_ sessionID: UUID) -> Bool {
        guard let agentID = state.workspace.session(sessionID)?.agentID else { return false }
        return agents[agentID]?.isAlive ?? false
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

    /// Claude Code projects on this Mac that aren't in the sidebar yet.
    public func importableProjects(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [DiscoveredProject] {
        do {
            return try discovery.discoverProjects(fileExists: fileExists)
                .filter { $0.exists && state.workspace.project(atPath: $0.path) == nil }
        } catch {
            errorMessage = "Couldn't read Claude Code projects: \(AppModel.describe(error))"
            return []
        }
    }

    /// Adds projects (with their existing sessions). Returns how many were new.
    @discardableResult
    public func importProjects(paths: [String]) -> Int {
        var added: [UUID] = []
        for path in paths where state.workspace.project(atPath: path) == nil {
            let id = state.workspace.addProject(path: path)
            importSessions(for: id)
            added.append(id)
        }
        if selectedSessionID == nil {
            selectedSessionID = state.workspace.sessions
                .filter { added.contains($0.projectID) && !$0.isArchived }
                .max { $0.lastActivity < $1.lastActivity }?.id
        }
        save()
        return added.count
    }

    public func removeProject(_ id: UUID) {
        let ids = state.workspace.sessions.filter { $0.projectID == id }.map(\.id)
        ids.forEach(detach)
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

    /// Selects a session and opens its tab.
    public func select(_ sessionID: UUID?) {
        selectedSessionID = sessionID
        guard let sessionID, state.workspace.session(sessionID) != nil else { return }
        recentSessionIDs.removeAll { $0 == sessionID }
        recentSessionIDs.insert(sessionID, at: 0)
        if !running.contains(sessionID) && isAgentAlive(sessionID) {
            // Reopening a live agent reattaches rather than showing the old terminal.
            exitCodes[sessionID] = nil
        }
        if !state.workspace.isOpen(sessionID) {
            state.workspace.openTab(sessionID)
            save()
        }
    }

    /// Closes a tab. The session keeps running (its sidebar status still
    /// updates) unless `stop` is true.
    public func closeTab(_ sessionID: UUID, stop shouldStop: Bool = false) {
        if selectedSessionID == sessionID {
            let open = tabs
            let index = open.firstIndex { $0.id == sessionID } ?? 0
            let remaining = open.filter { $0.id != sessionID }
            selectedSessionID = remaining.isEmpty ? nil : remaining[max(0, min(index - 1, remaining.count - 1))].id
        }
        state.workspace.closeTab(sessionID)
        recentSessionIDs.removeAll { $0 == sessionID }
        if shouldStop {
            stop(sessionID)
        } else if state.workspace.session(sessionID)?.agentID != nil {
            detach(sessionID)
        }
        save()
    }

    public func closeOtherTabs(keeping sessionID: UUID) {
        state.workspace.closeOtherTabs(keeping: sessionID)
        if let selected = selectedSessionID, !state.workspace.isOpen(selected) { select(sessionID) }
        save()
    }

    /// Closes completed tabs in the selected folder.
    public func closeCompletedTabs() {
        guard let group = selectedGroup else { return }
        let selected = selectedSessionID
        state.workspace.closeCompletedTabs(in: group)
        if let selected, !state.workspace.isOpen(selected) {
            selectedSessionID = state.workspace.openSessions(in: group).first?.id
        }
        save()
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
        detach(id)
        if let agentID = state.workspace.session(id)?.agentID {
            runAgentCommand { $0.remove(agentID: agentID) }
        }
        recentSessionIDs.removeAll { $0 == id }
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
        let background = state.settings.useBackgroundAgents && !prompt.isEmpty
        var session = Session(projectID: project.id,
                              claudeSessionID: background ? nil : UUID().uuidString.lowercased(),
                              name: name.isEmpty ? "New session" : name,
                              role: request.role,
                              workingDirectory: project.path,
                              model: request.model ?? state.settings.defaultModel,
                              permissionMode: request.permissionMode,
                              createdAt: now())
        session.hasCustomName = Workspace.trimmed(request.name) != nil
        if background { session.status = .working }
        guard attempt({ try state.workspace.addSession(session, toFolder: request.folderID) }) != nil else { return nil }
        select(session.id)
        save()
        if background {
            let worktree = request.useWorktree && isGitRepository(project.path)
                ? Worktree.uniqueName(for: Worktree.name(for: session.name), existing: Worktree.existingNames(in: project.path))
                : nil
            let id = session.id
            enqueue { await self.dispatch(id, prompt: prompt, worktree: worktree) }
        } else {
            start(session.id, prompt: prompt)
        }
        return session.id
    }

    // MARK: - Background agents

    /// Opens a session: reattaches a live agent, resumes a stopped one in the
    /// background, or (without an agent) starts `claude` directly.
    public func resume(_ sessionID: UUID) {
        guard let session = state.workspace.session(sessionID), !running.contains(sessionID) else { return }
        if isAgentAlive(sessionID) {
            attach(sessionID)
        } else if state.settings.useBackgroundAgents && session.hasConversation && session.claudeSessionID != nil {
            enqueue { await self.resumeInBackground(sessionID) }
        } else {
            start(sessionID)
        }
    }

    /// Re-reads `claude agents --json --all`: links and updates known
    /// sessions, and adds agents started elsewhere for projects in the sidebar.
    public func refreshAgents() async {
        guard let commands = agentCommands(reportErrors: false) else { return }
        let result = await runner.run(commands.list())
        guard result.exitCode == 0, let listed = try? AgentListParser.parse(Data(result.output.utf8)) else { return }
        apply(listed)
    }

    func apply(_ listed: [BackgroundAgent]) {
        var changed = false
        for agent in listed {
            let existing = state.workspace.sessions.first { $0.agentID == agent.id }
                ?? state.workspace.session(claudeSessionID: agent.sessionID)
            let stateKey = "\(agent.state ?? "")|\(agent.status ?? "")"
            if let existing {
                let stateChanged = appliedAgentStates[agent.id] != stateKey
                state.workspace.updateSession(existing.id) { session in
                    let before = session
                    session.agentID = agent.id
                    session.claudeSessionID = agent.sessionID
                    session.hasConversation = true
                    if !agent.cwd.isEmpty { session.workingDirectory = agent.cwd }
                    if let name = agent.name, !name.isEmpty, !session.hasCustomName { session.name = name }
                    if stateChanged {
                        session.status = agent.sessionStatus
                        session.needsAction = agent.sessionStatus == .awaitingInput ? (agent.waitingFor ?? session.needsAction) : nil
                    }
                    if session != before { changed = true }
                }
            } else if let projectID = state.workspace.projectID(forWorkingDirectory: agent.cwd) {
                var session = Session(projectID: projectID, claudeSessionID: agent.sessionID, hasConversation: true,
                                      name: agent.name ?? agent.id, workingDirectory: agent.cwd, status: agent.sessionStatus,
                                      createdAt: agent.startedAt ?? now())
                session.agentID = agent.id
                try? state.workspace.addSession(session)
                changed = true
            }
            appliedAgentStates[agent.id] = stateKey
        }
        let listedIDs = Set(listed.map(\.id))
        for session in state.workspace.sessions {
            if let agentID = session.agentID, !listedIDs.contains(agentID), agents[agentID] != nil {
                // Removed outside the app (`claude rm`).
                state.workspace.updateSession(session.id) { $0.agentID = nil }
                changed = true
            }
        }
        agents = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        if changed { save() }
    }

    /// For tests: a status change as a hook would make.
    func applyStatus(_ sessionID: UUID, _ status: SessionStatus) {
        state.workspace.updateSession(sessionID) { $0.status = status }
    }

    private func dispatch(_ sessionID: UUID, prompt: String, worktree: String?) async {
        guard let session = state.workspace.session(sessionID), let commands = agentCommands(reportErrors: true) else {
            applyStatus(sessionID, .completed)
            return
        }
        let result = await runner.run(commands.dispatch(session: session, prompt: prompt, worktree: worktree))
        await linkDispatched(sessionID, result: result)
    }

    private func resumeInBackground(_ sessionID: UUID) async {
        guard let session = state.workspace.session(sessionID), let commands = agentCommands(reportErrors: true) else { return }
        let result = await runner.run(commands.resume(session: session))
        await linkDispatched(sessionID, result: result)
    }

    private func linkDispatched(_ sessionID: UUID, result: CommandResult) async {
        guard state.workspace.session(sessionID) != nil else { return }
        guard result.exitCode == 0, let agentID = AgentListParser.dispatchedID(from: result.output + "\n" + result.errorOutput) else {
            errorMessage = "Couldn't start the agent: \(result.failureMessage)"
            applyStatus(sessionID, .completed)
            save()
            return
        }
        state.workspace.updateSession(sessionID) { session in
            session.agentID = agentID
            session.hasConversation = true
        }
        save()
        attach(sessionID)
        await refreshAgents()
    }

    private func attach(_ sessionID: UUID) {
        guard let session = state.workspace.session(sessionID), let agentID = session.agentID,
              let commands = agentCommands(reportErrors: true) else { return }
        pendingLaunches[sessionID] = commands.attach(agentID: agentID, workingDirectory: session.workingDirectory)
        running.insert(sessionID)
        exitCodes[sessionID] = nil
    }

    private func agentCommands(reportErrors: Bool) -> AgentCommands? {
        guard let executable = locateClaude(state.settings.claudePath) else {
            if reportErrors { errorMessage = "Claude Code CLI not found. Install it, or set its location in Settings." }
            return nil
        }
        return AgentCommands(claudeExecutable: executable, shell: shell, hookEventsPath: hookEventsURL.path)
    }

    /// Runs CLI work in order, one operation after another.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastTask
        lastTask = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func runAgentCommand(_ make: @escaping (AgentCommands) -> TerminalLaunch) {
        guard let commands = agentCommands(reportErrors: true) else { return }
        let runner = self.runner
        enqueue {
            let result = await runner.run(make(commands))
            if result.exitCode != 0 { self.errorMessage = "Claude Code: \(result.failureMessage)" }
            await self.refreshAgents()
        }
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
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Hooks confirm this shortly; an early exit resets it.
            state.workspace.updateSession(sessionID) { $0.status = .working; $0.lastActivity = now() }
            save()
        }
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
        if state.workspace.session(sessionID)?.agentID != nil {
            // Only the attach client ended; the agent's own state decides.
            enqueue { await self.refreshAgents() }
            return
        }
        state.workspace.updateSession(sessionID) { session in
            if session.status == .working { session.status = .completed }
        }
        save()
    }

    /// Stops the session: its background agent (`claude stop`) or its process.
    public func stop(_ sessionID: UUID) {
        detach(sessionID)
        if let agentID = state.workspace.session(sessionID)?.agentID {
            runAgentCommand { $0.stop(agentID: agentID) }
        }
    }

    /// Closes the session's terminal. For a background agent this only
    /// detaches; the agent keeps running.
    private func detach(_ sessionID: UUID) {
        let wasRunning = running.remove(sessionID) != nil
        pendingLaunches[sessionID] = nil
        if wasRunning { terminals?.terminate(sessionID) }
    }

    /// App quit: detach from background agents (they keep running) and stop
    /// directly-run sessions.
    public func shutdown() {
        Array(running).forEach(detach)
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
