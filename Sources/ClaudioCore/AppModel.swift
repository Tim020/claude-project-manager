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

/// The little the menu bar needs to know, kept apart from the rest of the
/// state so background refreshes don't rebuild the menus (an open menu would
/// flicker and resize).
public struct MenuFlags: Equatable, Sendable {
    public var hasProjects = false
    public var hasSelection = false
    public var canResumeSelected = false
    public var canStopSelected = false
    /// Claude Code can run (installed, signed in), or hasn't been checked yet.
    public var canRunSessions = true

    public init() {}
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
    /// What's known about the Claude Code CLI: installed, signed in, able to
    /// run background agents. Checked at launch and when Claudio comes back.
    public private(set) var environment = ClaudeEnvironment()
    public private(set) var isCheckingEnvironment = false
    /// Set when an action needed Claude Code but it can't run; the UI shows
    /// the setup sheet and clears it.
    public var setupRequested = false
    /// How long a check stays fresh before coming back to Claudio re-checks.
    public static let environmentCheckInterval: TimeInterval = 300

    /// Files each session changed, in both scopes (see AppModel+Changes).
    public internal(set) var sessionChanges: [UUID: SessionChangeState] = [:]
    /// "This Session" or "vs main", shared by the inspector and Changes view.
    public var changesScope: ChangesScope = .session
    public internal(set) var paneModes: [UUID: PaneMode] = [:]
    var selectedChanges: [UUID: String] = [:]
    /// The "vs" branch a session is switching to, shown until it has loaded.
    var pendingBaseNames: [UUID: String] = [:]
    @ObservationIgnored var pendingBaseTokens: [UUID: UUID] = [:]
    var expandedChanges: [UUID: String] = [:]
    @ObservationIgnored var changesDirty = Set<UUID>()
    @ObservationIgnored var refreshingChanges = Set<UUID>()
    @ObservationIgnored let editLogCache = EditLogCache()
    @ObservationIgnored let gitExecutable: String
    var changesRunner: CommandRunning { runner }

    /// A short notice shown over a session's terminal (e.g. why a key was
    /// ignored), cleared by `clearTerminalHint`.
    public private(set) var terminalHints: [UUID: String] = [:]

    /// Shows only sessions with this status in the sidebar (nil: all).
    public var statusFilter: SessionStatus?
    public var renamingFolderID: UUID?
    /// A user-facing error to show in an alert; the view clears it.
    public var errorMessage: String?
    private var running: Set<UUID> = []
    @ObservationIgnored private var pendingLaunches: [UUID: TerminalLaunch] = [:]
    private var exitCodes: [UUID: Int32] = [:]
    /// Read-only transcripts loaded from history files (see `loadHistory`).
    private var historyLines: [UUID: [TranscriptLine]] = [:]
    /// What the menu bar enables; refreshed with `updateMenuFlags()`.
    public private(set) var menuFlags = MenuFlags()
    /// Latest plan usage (from `claude /usage` or a session's status line).
    public private(set) var usage: UsageSnapshot?
    /// Context window use per session, from its status line.
    private var contexts: [UUID: ContextUsage] = [:]
    /// Context estimated from history, for sessions with no status line data.
    private var estimatedContexts: [UUID: ContextUsage] = [:]
    /// Sessions whose name still has to be written as their Claude Code title.
    @ObservationIgnored private var pendingTitlePushes = Set<UUID>()
    /// Most recently selected first; decides which tabs get split panes.
    private var recentSessionIDs: [UUID] = []
    /// Latest `claude agents` listing, by agent id.
    private var agents: [String: BackgroundAgent] = [:]
    /// Interactive `claude` processes running in terminals, by session id.
    private var terminalSessions: [String: InteractiveSession] = [:]
    /// A session the user asked to resume while it's open in a terminal;
    /// the UI asks whether to start a copy (`resumeCopy(of:)`).
    public var copyConfirmation: UUID?
    /// Agent state last applied per agent, so polling doesn't clobber newer
    /// hook updates with an unchanged state.
    @ObservationIgnored private var appliedAgentStates: [String: String] = [:]
    /// The most recent background CLI operation (awaited by tests).
    @ObservationIgnored public private(set) var lastTask: Task<Void, Never>?
    /// Commands, terminals and errors, for the Activity Log window.
    @ObservationIgnored public let log: ActivityLog
    @ObservationIgnored private let summaryCache = SessionSummaryCache()
    @ObservationIgnored private var lastOutputs: [String: String] = [:]
    @ObservationIgnored private var isRefreshingAgents = false
    @ObservationIgnored private var isRefreshingProjects = false
    /// The message to send once the user confirms resuming a copy.
    @ObservationIgnored private var pendingCopyMessages: [UUID: String] = [:]

    @ObservationIgnored public weak var terminals: TerminalControlling?
    @ObservationIgnored public weak var notifier: NotificationPosting?
    /// Whether Claudio is the frontmost app (set by the UI); notifications
    /// skip the session you're looking at only while it is.
    @ObservationIgnored public var appIsActive = false
    @ObservationIgnored private var notificationBaseline: [UUID: NotificationBaseline]?
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored let discovery: SessionDiscovery
    @ObservationIgnored private let hookEventsURL: URL
    @ObservationIgnored private let usageURL: URL?
    @ObservationIgnored private var usageModified: Date?
    @ObservationIgnored private let statusDirectory: URL?
    @ObservationIgnored private var statusModified: [String: Date] = [:]
    @ObservationIgnored private var hookTailer: HookEventTailer
    @ObservationIgnored private let runner: CommandRunning
    @ObservationIgnored private let locateClaude: (String?) -> String?
    @ObservationIgnored let locateGitHubCLI: () -> String?
    /// `gh pr view` results per folder (nil: no pull request), briefly cached.
    @ObservationIgnored var pullRequestCache: [String: (pullRequest: GitHubCLI.PullRequest?, checked: Date)] = [:]
    public static let pullRequestCacheInterval: TimeInterval = 300
    @ObservationIgnored private let isGitRepository: (String) -> Bool
    @ObservationIgnored private let shell: String
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored public let home: String

    public init(
        store: StateStore,
        discovery: SessionDiscovery,
        hookEventsURL: URL,
        usageURL: URL? = nil,
        statusDirectory: URL? = nil,
        runner: CommandRunning = ProcessCommandRunner(),
        git: String = GitChanges.defaultGit,
        locateClaude: @escaping (String?) -> String? = { ClaudeExecutableLocator.locate(override: $0) },
        locateGitHubCLI: @escaping () -> String? = { GitHubCLI.locate() },
        isGitRepository: @escaping (String) -> Bool = Worktree.isGitRepository,
        shell: String = ClaudeExecutableLocator.defaultShell(),
        now: @escaping () -> Date = Date.init,
        home: String = NSHomeDirectory(),
        logFileURL: URL? = nil
    ) {
        self.log = ActivityLog(fileURL: logFileURL)
        self.store = store
        self.discovery = discovery
        self.hookEventsURL = hookEventsURL
        self.usageURL = usageURL
        self.statusDirectory = statusDirectory
        self.hookTailer = HookEventTailer(url: hookEventsURL, startAtEnd: true)
        self.runner = runner
        self.gitExecutable = git
        self.locateClaude = locateClaude
        self.locateGitHubCLI = locateGitHubCLI
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
        log.append(.info, "Claudio started", detail: errorMessage)
        pollUsage()
        // Nothing is running at launch, whatever was saved.
        for session in state.workspace.sessions where session.status == .working {
            state.workspace.updateSession(session.id) { $0.status = .completed }
        }
    }

    // MARK: - Derived state

    public var workspace: Workspace { state.workspace }
    public var settings: AppSettings { state.settings }

    public var sidebar: [SidebarProject] {
        Sidebar.build(state.workspace, filter: filterText, status: statusFilter,
                      activeSince: state.settings.activitySince(now: now()), alwaysShow: alwaysShownSessionIDs, home: home)
    }

    /// Sessions shown whatever their age: open tabs, the selection, and ones
    /// with a live terminal.
    private var alwaysShownSessionIDs: Set<UUID> {
        var ids = Set(state.workspace.openTabIDs).union(running)
        if let selectedSessionID { ids.insert(selectedSessionID) }
        return ids
    }

    /// How many sessions the recent-activity window is hiding.
    public var hiddenByRecencyCount: Int {
        Sidebar.hiddenByRecency(state.workspace, activeSince: state.settings.activitySince(now: now()), alwaysShow: alwaysShownSessionIDs)
    }

    /// Sets the recent-activity window in days (0: show every session).
    public func setActivityWindow(days: Int) {
        var settings = state.settings
        settings.activityWindowDays = max(0, days)
        updateSettings(settings)
    }

    public var selectedSession: Session? {
        selectedSessionID.flatMap { state.workspace.session($0) }
    }

    public var selectedGroup: SessionGroup? {
        selectedSessionID.flatMap { state.workspace.group(of: $0) }
    }

    /// Open tabs, across folders and projects, in the order they were opened.
    public var tabs: [Session] {
        state.workspace.openTabSessions
    }

    /// Whether the open tabs come from more than one folder (tabs then show
    /// where each session lives).
    public var tabsSpanFolders: Bool {
        Set(tabs.compactMap { state.workspace.group(of: $0.id) }).count > 1
    }

    /// Sessions in the selected folder whose tabs are closed (to reopen).
    public var closedTabs: [Session] {
        guard let group = selectedGroup else { return [] }
        return state.workspace.sessions(in: group).filter { !state.workspace.isOpen($0.id) }
    }

    /// Split view shows open tabs side by side, so it needs at least two.
    public var canSplit: Bool {
        tabs.count > 1
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

    /// The sidebar footer's counts: what the text filter and recent-activity
    /// window show, but not the status filter, since the footer's counts are
    /// the status filter's buttons.
    public var footerStatusCounts: StatusCounts {
        Sidebar.build(state.workspace, filter: filterText, status: nil,
                      activeSince: state.settings.activitySince(now: now()), alwaysShow: alwaysShownSessionIDs, home: home)
            .reduce(StatusCounts()) { $0 + $1.statusCounts }
    }

    /// Whether the session has a live terminal in the app.
    public func isRunning(_ sessionID: UUID) -> Bool {
        running.contains(sessionID)
    }

    /// Whether the session is open in an interactive `claude` in a terminal.
    public func isOpenInTerminal(_ sessionID: UUID) -> Bool {
        guard let claudeID = state.workspace.session(sessionID)?.claudeSessionID else { return false }
        return terminalSessions[claudeID] != nil
    }

    /// Whether the session's background agent process is alive (it may be
    /// running without a terminal attached).
    /// Sessions whose status comes from a live process (a terminal here or a
    /// running background agent), which history files mustn't override.
    private var liveSessionIDs: Set<UUID> {
        running.union(state.workspace.sessions.filter { isAgentAlive($0.id) }.map(\.id))
    }

    public func isAgentAlive(_ sessionID: UUID) -> Bool {
        guard let agentID = state.workspace.session(sessionID)?.agentID else { return false }
        return agents[agentID]?.isAlive ?? false
    }

    /// Exit code of the session's last terminal, if it has exited since it was started.
    public func lastExitCode(_ sessionID: UUID) -> Int32? {
        exitCodes[sessionID]
    }

    /// Read-only transcript from Claude Code's history file, for sessions that
    /// aren't running. Empty until `loadHistory` has run.
    public func history(for sessionID: UUID) -> [TranscriptLine] {
        historyLines[sessionID] ?? []
    }

    /// Reads a session's history file off the main actor (they can be large).
    public func loadHistory(_ sessionID: UUID) async {
        guard let session = state.workspace.session(sessionID) else { return }
        guard session.hasConversation, let claudeID = session.claudeSessionID else {
            historyLines[sessionID] = []
            return
        }
        let discovery = self.discovery
        let directory = session.workingDirectory
        let lines = await Task.detached(priority: .userInitiated) { () -> [TranscriptLine] in
            var builder = TranscriptBuilder(workingDirectory: directory)
            (try? discovery.loadHistory(projectPath: directory, claudeSessionID: claudeID))?.forEach { builder.apply($0) }
            return builder.lines
        }.value
        if historyLines[sessionID] != lines { historyLines[sessionID] = lines }
    }

    // MARK: - Projects

    @discardableResult
    public func addProject(path: String) -> UUID {
        let id = state.workspace.addProject(path: path)
        importSessions(for: id)
        save()
        return id
    }

    /// Checks the CLI: `claude --version`, `claude auth status` and whether
    /// `claude agents` works. Unless `force`, skips if checked recently.
    public func checkEnvironment(force: Bool = false) async {
        if isCheckingEnvironment { return }
        if !force, let checked = environment.checkedAt, now().timeIntervalSince(checked) < AppModel.environmentCheckInterval { return }
        isCheckingEnvironment = true
        defer { isCheckingEnvironment = false }

        var result = ClaudeEnvironment()
        result.checkedAt = now()
        result.githubCLI = await checkGitHubCLI()
        guard let executable = locateClaude(state.settings.claudePath), let commands = agentCommands(reportErrors: false) else {
            result.install = .notFound
            publish(result)
            return
        }
        let version = await run(commands.version())
        guard version.exitCode == 0 else {
            let message = [version.errorOutput, version.output]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(version.exitCode)"
            result.install = .broken(path: executable, message: String(message.prefix(300)))
            publish(result)
            return
        }
        result.install = .installed(path: executable, version: ClaudeVersion.parse(version.output))

        // Account details stay out of the log.
        let auth = await run(commands.authStatus(), hideOutput: true)
        if let status = ClaudeAuthStatus.parse(auth.output) {
            result.signIn = status.loggedIn ? .signedIn(status) : .signedOut
        } else {
            result.signIn = .unknown
        }

        let agents = await run(commands.list(), logOnlyChanges: true)
        if agents.exitCode == 0, (try? AgentListParser.parse(Data(agents.output.utf8))) != nil {
            result.agents = .supported
        } else if (agents.errorOutput + agents.output).lowercased().contains("unknown") {
            result.agents = .unsupported(message: agents.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        publish(result)
    }

    private func publish(_ result: ClaudeEnvironment) {
        let problems = result.problems.map(\.title)
        if problems != environment.problems.map(\.title) || environment.checkedAt == nil {
            log.append(problems.isEmpty ? .info : .error, problems.isEmpty ? "Claude Code is ready" : "Claude Code needs attention",
                       detail: problems.isEmpty ? result.version.map { "Version \($0)" } : problems.joined(separator: "\n"))
        }
        if result != environment { environment = result }
    }

    /// `gh auth status` (account names stay out of the log).
    private func checkGitHubCLI() async -> ClaudeEnvironment.GitHubCLIState {
        guard let gh = locateGitHubCLI() else { return .notInstalled }
        let status = await run(GitHubCLI.command(["auth", "status"], in: home, gh: gh), hideOutput: true)
        switch GitHubCLI.parseAuthStatus(status.output + "\n" + status.errorOutput) {
        case .signedIn(let account): return .signedIn(path: gh, account: account)
        case .signedOut: return .signedOut(path: gh)
        }
    }

    /// The command that fixes a problem, run in a terminal so its output
    /// and any prompts show. `chooseExecutable` is handled by the UI.
    public func fixLaunch(for fix: EnvironmentFix) -> TerminalLaunch? {
        switch fix {
        case .install:
            return TerminalLaunch.script(TerminalLaunch.installScript, workingDirectory: home, shell: shell)
        case .update:
            return agentCommands(reportErrors: false)?.update()
        case .signIn:
            return agentCommands(reportErrors: false)?.signIn()
        case .chooseExecutable:
            return nil
        case .installGitHubCLI:
            // Homebrew if there is one; otherwise the UI opens cli.github.com.
            guard ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
            return TerminalLaunch.script("brew install gh", workingDirectory: home, shell: shell)
        case .signInGitHubCLI:
            guard let gh = locateGitHubCLI() else { return nil }
            var launch = TerminalLaunch.script("exec \(ShellQuote.quote(gh)) auth login", workingDirectory: home, shell: shell)
            launch.label = "gh auth login"
            return launch
        }
    }

    /// New sessions run as background agents: on in Settings, and the CLI
    /// supports them.
    public var backgroundAgentsEnabled: Bool {
        state.settings.useBackgroundAgents && environment.backgroundAgentsAvailable
    }

    /// Reads one project in each protected location (Documents, Desktop…) so
    /// macOS asks for any access it needs at launch, not mid-action.
    public func preflightFolderAccess(probe: @escaping @Sendable (String) -> Void = FolderAccess.touch) async {
        let probes = FolderAccess.probePaths(for: state.workspace.projects.map(\.path), home: home)
        guard !probes.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for (_, path) in probes { probe(path) }
        }.value
        log.append(.info, "Checked folder access at launch",
                   detail: probes.map { "\($0.0.rawValue): \(PathDisplay.tilde($0.1, home: home))" }.joined(separator: "\n"))
    }

    /// Claude Code projects on this Mac that aren't in the sidebar yet.
    public func importableProjects(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [DiscoveredProject] {
        importCandidates(fileExists: fileExists).projects
    }

    /// Importable projects, plus the paths skipped because the folder is gone.
    public func importCandidates(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ImportCandidates {
        do {
            let found = try discovery.discoverProjects(fileExists: fileExists)
                .filter { state.workspace.project(atPath: $0.path) == nil }
            return ImportCandidates(projects: found.filter(\.exists), missingPaths: found.filter { !$0.exists }.map(\.path).sorted())
        } catch {
            report("Couldn't read Claude Code projects: \(AppModel.describe(error))")
            return ImportCandidates(projects: [], missingPaths: [])
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

    public func toggleCollapsed(_ group: SessionGroup) {
        state.workspace.toggleCollapsed(group)
        save()
    }

    public func toggleCollapsed(_ projectID: UUID) {
        state.workspace.toggleCollapsed(projectID)
        save()
    }

    /// Re-reads every project's sessions from disk (e.g. ones run in another
    /// terminal). History files are read off the main actor and cached, so
    /// only files that changed are parsed again.
    public func refreshAll() async {
        await refreshProjects(state.workspace.projects.map(\.id))
    }

    func refreshProjects(_ ids: [UUID]) async {
        guard !isRefreshingProjects else { return }
        isRefreshingProjects = true
        defer { isRefreshingProjects = false }
        let targets = ids.compactMap { id in state.workspace.project(id).map { (id, $0.path, $0.name) } }
        let discovery = self.discovery
        let cache = self.summaryCache
        let results = await Task.detached(priority: .utility) {
            targets.map { id, path, name in (id, name, Result { try discovery.discover(projectPath: path, cache: cache) }) }
        }.value
        var workspace = state.workspace
        var estimates = estimatedContexts
        for (id, name, result) in results {
            switch result {
            case .success(let found):
                workspace.importDiscovered(found, into: id, skipping: liveSessionIDs)
                AppModel.recordEstimates(found, in: workspace, into: &estimates)
            case .failure(let error): log.append(.error, "Couldn't read Claude Code sessions for \(name)", detail: AppModel.describe(error))
            }
        }
        if workspace != state.workspace {
            state.workspace = workspace
            save()
        }
        if estimates != estimatedContexts { estimatedContexts = estimates }
        if !pendingTitlePushes.isEmpty {
            flushTitlePushes()
            save()
        }
    }

    private static func recordEstimates(_ found: [DiscoveredSession], in workspace: Workspace, into estimates: inout [UUID: ContextUsage]) {
        for discovered in found {
            guard let session = workspace.session(claudeSessionID: discovered.claudeSessionID) else { continue }
            estimates[session.id] = discovered.contextTokens.map { ContextUsage.estimate(tokens: $0, model: discovered.model) }
        }
    }

    private func importSessions(for projectID: UUID) {
        guard let project = state.workspace.project(projectID) else { return }
        do {
            let found = try discovery.discover(projectPath: project.path, cache: summaryCache)
            state.workspace.importDiscovered(found, into: projectID, skipping: liveSessionIDs)
            AppModel.recordEstimates(found, in: state.workspace, into: &estimatedContexts)
        } catch {
            report("Couldn't read Claude Code sessions for \(project.name): \(AppModel.describe(error))")
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

    /// Closes the tabs left of `sessionID` (which stays open).
    public func closeTabs(leftOf sessionID: UUID) {
        closeTabs(state.workspace.tabIDs(leftOf: sessionID), fallback: sessionID)
    }

    /// Closes the tabs right of `sessionID` (which stays open).
    public func closeTabs(rightOf sessionID: UUID) {
        closeTabs(state.workspace.tabIDs(rightOf: sessionID), fallback: sessionID)
    }

    /// Closes every tab. Sessions keep running.
    public func closeAllTabs() {
        closeTabs(tabs.map(\.id), fallback: nil)
    }

    /// Closes several tabs, detaching from their agents; if the selected tab
    /// closes, `fallback` is selected instead.
    private func closeTabs(_ ids: [UUID], fallback: UUID?) {
        guard !ids.isEmpty else { return }
        for id in ids {
            state.workspace.closeTab(id)
            recentSessionIDs.removeAll { $0 == id }
            if state.workspace.session(id)?.agentID != nil { detach(id) }
        }
        if let selected = selectedSessionID, ids.contains(selected) { selectedSessionID = fallback }
        save()
    }

    /// Shows only sessions with `status` in the sidebar, or all again if it's
    /// already the filter.
    public func toggleStatusFilter(_ status: SessionStatus) {
        statusFilter = statusFilter == status ? nil : status
    }

    /// Closes every completed tab.
    public func closeCompletedTabs() {
        let selected = selectedSessionID
        state.workspace.closeCompletedTabs()
        if let selected, !state.workspace.isOpen(selected) {
            selectedSessionID = tabs.first?.id
        }
        save()
    }

    public func moveSession(_ id: UUID, to group: SessionGroup, at index: Int? = nil) {
        attempt { try state.workspace.moveSession(id, to: group, at: index) }
        save()
    }

    /// Drag to reorder: places the session just before another one.
    public func moveSession(_ id: UUID, before targetID: UUID) {
        attempt { try state.workspace.moveSession(id, before: targetID) }
        save()
    }

    /// Renames a session here and in Claude Code (its title, as `/rename` sets).
    public func renameSession(_ id: UUID, to name: String) {
        guard attempt({ try state.workspace.renameSession(id, to: name) }) != nil else { return }
        pushTitle(id)
        save()
    }

    /// Writes the session's name as its Claude Code title, once the session
    /// has a history file. Sessions still waiting for one are retried after
    /// the next refresh.
    @discardableResult
    private func pushTitle(_ id: UUID) -> Bool {
        guard let session = state.workspace.session(id), let claudeID = session.claudeSessionID else {
            pendingTitlePushes.insert(id)
            return false
        }
        let file = discovery.historyFile(projectPath: session.workingDirectory, claudeSessionID: claudeID)
        guard SessionTitleWriter.append(title: session.name, claudeSessionID: claudeID, to: file) else {
            pendingTitlePushes.insert(id)
            return false
        }
        pendingTitlePushes.remove(id)
        state.workspace.updateSession(id) { $0.claudeTitle = session.name }
        log.append(.info, "Set Claude Code's title for “\(session.name)”", detail: PathDisplay.tilde(file.path, home: home))
        return true
    }

    private func flushTitlePushes() {
        for id in pendingTitlePushes {
            guard let session = state.workspace.session(id), session.hasCustomName else { pendingTitlePushes.remove(id); continue }
            if session.claudeTitle == session.name { pendingTitlePushes.remove(id); continue }
            pushTitle(id)
        }
    }

    /// Remembers the branch a session was last compared against (saved only
    /// when it changes).
    func recordBaseName(_ name: String, for sessionID: UUID) {
        guard let session = state.workspace.session(sessionID), session.lastBaseName != name else { return }
        state.workspace.updateSession(sessionID) { $0.lastBaseName = name }
        save()
    }

    /// Sets the branch "vs" compares against for a project's sessions without
    /// a pull request (nil: the repository's default branch).
    public func setComparisonBranch(_ branch: String?, for projectID: UUID) {
        guard var project = state.workspace.project(projectID), project.comparisonBranch != branch else { return }
        project.comparisonBranch = branch
        state.workspace.replaceProject(project)
        save()
        for session in state.workspace.sessions where session.projectID == projectID {
            markChangesDirty(session.id)
            // An open pull request's base still wins, so nothing changes there.
            if case .pullRequest? = (try? sessionChanges[session.id]?.git?.get())?.baseSource { continue }
            pendingBaseNames[session.id] = branch ?? "default branch"
            pendingBaseTokens[session.id] = UUID()
        }
    }

    public func setRole(_ id: UUID, to role: SessionRole) {
        guard let session = state.workspace.session(id), session.role != role else { return }
        state.workspace.updateSession(id) { $0.role = role }
        save()
    }

    /// Roles offered for a session: the Settings list, plus its current role
    /// if that has since been removed from the list.
    public func roleChoices(for id: UUID) -> [SessionRole] {
        var choices = settings.roles.map { SessionRole($0) }
        if let current = state.workspace.session(id)?.role, !current.isNone,
           !choices.contains(where: { $0.rawValue.caseInsensitiveCompare(current.rawValue) == .orderedSame }) {
            choices.append(current)
        }
        return choices
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
        historyLines[id] = nil
        state.workspace.removeSession(id)
        save()
    }

    /// Adds a session, selects it and opens its terminal (with the prompt, if any).
    @discardableResult
    public func createSession(_ request: NewSessionRequest) -> UUID? {
        guard let project = state.workspace.project(request.projectID) else { return nil }
        guard environment.canRunSessions else {
            setupRequested = true
            return nil
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = Workspace.trimmed(request.name)
            ?? SessionDiscovery.truncateAtWord(TranscriptBuilder.firstLine(prompt), to: SessionDiscovery.maxTitleLength)
        let background = backgroundAgentsEnabled && !prompt.isEmpty
        var session = Session(projectID: project.id,
                              claudeSessionID: background ? nil : UUID().uuidString.lowercased(),
                              name: name.isEmpty ? "New session" : name,
                              role: request.role,
                              workingDirectory: project.path,
                              model: request.model ?? state.settings.defaultModel,
                              permissionMode: request.permissionMode,
                              createdAt: now())
        session.hasCustomName = Workspace.trimmed(request.name) != nil
        // Give Claude Code the same name once the session has a history file.
        if session.hasCustomName { pendingTitlePushes.insert(session.id) }
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
    /// background, or (without an agent) starts `claude` directly. A message,
    /// if given, is sent as the first prompt after resuming.
    public func resume(_ sessionID: UUID, message: String? = nil) {
        guard let session = state.workspace.session(sessionID), !running.contains(sessionID) else { return }
        guard environment.canRunSessions || isAgentAlive(sessionID) else {
            setupRequested = true
            return
        }
        let message = message.flatMap(Workspace.trimmed)
        if isAgentAlive(sessionID) {
            attach(sessionID)
        } else if isOpenInTerminal(sessionID) {
            // Resuming would fork the conversation; let the user decide.
            pendingCopyMessages[sessionID] = message
            copyConfirmation = sessionID
        } else if backgroundAgentsEnabled && session.hasConversation && session.claudeSessionID != nil {
            if message != nil { markWorking(sessionID) }
            enqueue { await self.resumeInBackground(sessionID, prompt: message) }
        } else {
            start(sessionID, prompt: message)
        }
    }

    /// Starts a background copy of a session that's open in a terminal.
    public func resumeCopy(of sessionID: UUID) {
        copyConfirmation = nil
        let message = pendingCopyMessages.removeValue(forKey: sessionID)
        enqueue { await self.resumeInBackground(sessionID, prompt: message) }
    }

    private func markWorking(_ sessionID: UUID) {
        state.workspace.updateSession(sessionID) { $0.status = .working; $0.needsAction = nil; $0.lastActivity = now() }
        save()
    }

    /// Re-reads `claude agents --json --all`: links and updates known
    /// sessions, and adds agents started elsewhere for projects in the sidebar.
    public func refreshAgents() async {
        guard !isRefreshingAgents, environment.canRunSessionsOrUnchecked, let commands = agentCommands(reportErrors: false) else { return }
        isRefreshingAgents = true
        defer { isRefreshingAgents = false }
        let result = await run(commands.list(), logOnlyChanges: true)
        let data = Data(result.output.utf8)
        guard result.exitCode == 0, let listed = try? AgentListParser.parse(data) else { return }
        apply(listed)
        applyTerminalSessions((try? AgentListParser.parseInteractive(data)) ?? [])
    }

    func applyTerminalSessions(_ listed: [InteractiveSession]) {
        var changed = false
        var unknownProjects = Set<UUID>()
        for terminal in listed {
            guard let session = state.workspace.session(claudeSessionID: terminal.sessionID) else {
                if let project = state.workspace.projectID(forWorkingDirectory: terminal.cwd) { unknownProjects.insert(project) }
                continue
            }
            let key = "terminal|\(terminal.status ?? "")"
            guard appliedAgentStates[terminal.sessionID] != key else { continue }
            appliedAgentStates[terminal.sessionID] = key
            state.workspace.updateSession(session.id) { session in
                if terminal.isBusy {
                    session.status = .working
                    session.needsAction = nil
                } else if session.status == .working {
                    session.status = .completed
                }
                session.lastActivity = now()
            }
            changed = true
        }
        let bySession = Dictionary(listed.map { ($0.sessionID, $0) }, uniquingKeysWith: { $1 })
        if terminalSessions != bySession { terminalSessions = bySession }
        // A new terminal session in a known project: pick it up from its history.
        if !unknownProjects.isEmpty {
            let ids = Array(unknownProjects)
            Task { await self.refreshProjects(ids) }
        }
        if changed { save() }
    }

    func apply(_ listed: [BackgroundAgent]) {
        // Work on a copy and only publish real changes: this runs every few
        // seconds, and every change to observed state redraws views.
        var workspace = state.workspace
        // Sessions already linked to a listed agent keep it: an agent whose
        // conversation id matches another session's (a copy of it) mustn't
        // take that session over.
        let listedIDs = Set(listed.map(\.id))
        var claimed = Set(workspace.sessions.filter { $0.agentID.map(listedIDs.contains) == true }.map(\.id))
        for agent in listed {
            var existing = workspace.sessions.first { $0.agentID == agent.id }
            if existing == nil, let match = workspace.session(claudeSessionID: agent.sessionID), !claimed.contains(match.id) {
                existing = match
            }
            if let existing { claimed.insert(existing.id) }
            let stateKey = "\(agent.state ?? "")|\(agent.status ?? "")"
            if let existing {
                let stateChanged = appliedAgentStates[agent.id] != stateKey
                workspace.updateSession(existing.id) { session in
                    session.agentID = agent.id
                    session.claudeSessionID = agent.sessionID
                    session.hasConversation = true
                    if !agent.cwd.isEmpty { session.workingDirectory = agent.cwd }
                    if let name = agent.name, !name.isEmpty, !session.hasCustomName { session.name = name }
                    if stateChanged {
                        session.status = agent.sessionStatus
                        session.needsAction = agent.sessionStatus == .awaitingInput ? (agent.waitingFor ?? session.needsAction) : nil
                    }
                }
            } else if let projectID = workspace.projectID(forWorkingDirectory: agent.cwd) {
                var session = Session(projectID: projectID, claudeSessionID: agent.sessionID, hasConversation: true,
                                      name: agent.name ?? agent.id, workingDirectory: agent.cwd, status: agent.sessionStatus,
                                      createdAt: agent.startedAt ?? now())
                session.agentID = agent.id
                try? workspace.addSession(session)
            }
            appliedAgentStates[agent.id] = stateKey
        }
        for session in workspace.sessions {
            if let agentID = session.agentID, !listedIDs.contains(agentID), agents[agentID] != nil {
                // Removed outside the app (`claude rm`).
                workspace.updateSession(session.id) { $0.agentID = nil }
            }
        }
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        if agents != byID { agents = byID }
        if workspace != state.workspace {
            state.workspace = workspace
            save()
        }
    }

    /// For tests: links a session to an agent as a dispatch would.
    func applyAgentLink(_ sessionID: UUID, agentID: String) {
        state.workspace.updateSession(sessionID) { $0.agentID = agentID }
    }

    /// For tests: a status change as a hook would make.
    func applyStatus(_ sessionID: UUID, _ status: SessionStatus, summary: String? = nil) {
        state.workspace.updateSession(sessionID) { session in
            session.status = status
            if let summary { session.summary = summary }
        }
    }

    /// For tests: a permission request as the Notification hook reports it.
    func applyNeedsAction(_ sessionID: UUID, _ text: String) {
        state.workspace.updateSession(sessionID) { $0.status = .awaitingInput; $0.needsAction = text }
    }

    private func dispatch(_ sessionID: UUID, prompt: String, worktree: String?) async {
        guard let session = state.workspace.session(sessionID), let commands = agentCommands(reportErrors: true) else {
            applyStatus(sessionID, .completed)
            return
        }
        let result = await run(commands.dispatch(session: session, prompt: prompt, worktree: worktree))
        await linkDispatched(sessionID, result: result)
    }

    private func resumeInBackground(_ sessionID: UUID, prompt: String? = nil) async {
        guard let session = state.workspace.session(sessionID), let commands = agentCommands(reportErrors: true) else { return }
        let result = await run(commands.resume(session: session, prompt: prompt, continuingAgent: session.agentID != nil))
        await linkDispatched(sessionID, result: result)
    }

    private func linkDispatched(_ sessionID: UUID, result: CommandResult) async {
        guard state.workspace.session(sessionID) != nil else { return }
        guard result.exitCode == 0, let agentID = AgentListParser.dispatchedID(from: result.output + "\n" + result.errorOutput) else {
            report("Couldn't start the agent: \(result.failureMessage)")
            applyStatus(sessionID, .completed)
            save()
            return
        }
        if let copyID = AgentListParser.copiedID(from: result.output + "\n" + result.errorOutput) {
            addCopy(of: sessionID, agentID: copyID)
            await refreshAgents()
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

    /// The CLI started a copy of the conversation: keep it as its own
    /// session beside the original rather than relinking the original.
    private func addCopy(of originalID: UUID, agentID: String) {
        guard let original = state.workspace.session(originalID) else { return }
        var copy = Session(projectID: original.projectID, hasConversation: true, name: "\(original.name) (copy)",
                           role: original.role, workingDirectory: original.workingDirectory, status: .working,
                           model: original.model, permissionMode: original.permissionMode, createdAt: now())
        copy.agentID = agentID
        copy.hasCustomName = true
        var folderID: UUID?
        if case .folder(let id)? = state.workspace.group(of: originalID) { folderID = id }
        try? state.workspace.addSession(copy, toFolder: folderID)
        select(copy.id)
        save()
        attach(copy.id)
    }

    /// Claude Code's agents view took over an attached terminal (a ← on an
    /// empty prompt): queue a fresh `claude attach` so the tab shows its
    /// session again. The UI swaps the terminal in place.
    @discardableResult
    public func returnToSession(_ sessionID: UUID) -> Bool {
        guard let session = state.workspace.session(sessionID), session.agentID != nil else { return false }
        log.append(.info, "Returned to “\(session.name)” after ← opened Claude Code's agents view")
        attach(sessionID)
        return running.contains(sessionID)
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
            if reportErrors { report("Claude Code CLI not found. Install it, or set its location in Settings.") }
            return nil
        }
        return AgentCommands(claudeExecutable: executable, shell: shell, hookEventsPath: hookEventsURL.path,
                             statusLine: statusLineCapture())
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
        enqueue {
            let result = await self.run(make(commands))
            if result.exitCode != 0 { self.report("Claude Code: \(result.failureMessage)") }
            await self.refreshAgents()
        }
    }

    /// Runs a CLI command off the main actor and records it in the log.
    /// Polling commands are only logged when their output changes or they fail.
    func run(_ command: TerminalLaunch, logOnlyChanges: Bool = false, changeKey: String = "agents",
                     hideOutput: Bool = false) async -> CommandResult {
        let started = Date()
        let result = await runner.run(command)
        let changed = lastOutputs[changeKey] != result.output
        if logOnlyChanges { lastOutputs[changeKey] = result.output }
        if !logOnlyChanges || changed || result.exitCode != 0 {
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            var detail = "exit \(result.exitCode) · \(milliseconds) ms · in \(command.workingDirectory)"
            for (label, text) in hideOutput ? [] : [("stdout", result.output), ("stderr", result.errorOutput)] {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { detail += "\n\(label):\n" + String(trimmed.prefix(4000)) }
            }
            log.append(.command, command.displayCommand, detail: detail)
        }
        return result
    }

    /// Queues a terminal launch for the session (new or `--resume`). Returns
    /// false if it is already running or `claude` can't be found.
    @discardableResult
    public func start(_ sessionID: UUID, prompt: String? = nil) -> Bool {
        guard !running.contains(sessionID), let session = state.workspace.session(sessionID) else { return false }
        guard let executable = locateClaude(state.settings.claudePath) else {
            report("Claude Code CLI not found. Install it, or set its location in Settings.")
            return false
        }
        try? FileManager.default.createDirectory(at: hookEventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        pendingLaunches[sessionID] = TerminalLaunch.make(session: session, claudeExecutable: executable, shell: shell,
                                                         initialPrompt: prompt, hookEventsPath: hookEventsURL.path,
                                                         statusLine: statusLineCapture())
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
        guard let launch = pendingLaunches.removeValue(forKey: sessionID) else { return nil }
        log.append(.terminal, "Terminal started: \(launch.displayCommand)",
                   detail: "in \(launch.workingDirectory)\n\(launch.executable) \(launch.arguments.dropLast().joined(separator: " "))")
        return launch
    }

    /// Called by the UI when a session's terminal process exits.
    public func terminalExited(_ sessionID: UUID, exitCode: Int32?) {
        running.remove(sessionID)
        pendingLaunches[sessionID] = nil
        exitCodes[sessionID] = exitCode ?? 0
        let name = state.workspace.session(sessionID)?.name ?? sessionID.uuidString
        log.append(.terminal, exitCode.map { "Terminal exited (code \($0)): \(name)" } ?? "Terminal exited: \(name)")
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
        for event in events {
            guard let target = hookTarget(for: event) else { continue }
            state.workspace.updateSession(target) { HookReducer.apply(event, to: &$0, now: now()) }
            // A tool may have changed files.
            if event.name == .postToolUse || event.name == .stop { markChangesDirty(target) }
            changed = true
        }
        if changed { save() }
    }

    /// The session a hook event belongs to. Events carry the app id of the
    /// session whose settings launched the process, but a copy of that
    /// conversation (started by the CLI) inherits those settings, so the
    /// event's own conversation id decides:
    /// - a session with that conversation id;
    /// - otherwise the launching session, if it has no conversation yet or
    ///   `/clear` just started a new one;
    /// - otherwise the background agent whose short id prefixes it (a copy);
    /// - otherwise nobody, rather than repointing the launching session.
    private func hookTarget(for event: HookEvent) -> UUID? {
        let workspace = state.workspace
        guard let claudeID = event.claudeSessionID, !claudeID.isEmpty else {
            return workspace.session(event.appSessionID)?.id
        }
        if let session = workspace.session(claudeSessionID: claudeID) { return session.id }
        if let owner = workspace.session(event.appSessionID),
           owner.claudeSessionID == nil || (event.name == .sessionStart && event.source == "clear") {
            return owner.id
        }
        let shortID = String(claudeID.prefix(8))
        return workspace.sessions.first { $0.agentID == shortID }?.id
    }

    /// A second Ctrl+C / Ctrl+D would have quit Claude Code in this terminal.
    public func exitKeyBlocked(_ sessionID: UUID) {
        let agent = state.workspace.session(sessionID)?.agentID != nil
        terminalHints[sessionID] = agent
            ? "Claudio keeps Claude Code open here. Close the tab to detach (it keeps running), or use Stop Session."
            : "Claudio keeps Claude Code open here. Use Stop Session to end it."
        log.append(.info, "Blocked a second Ctrl+C/Ctrl+D that would have quit Claude Code")
    }

    public func clearTerminalHint(_ sessionID: UUID) {
        if terminalHints[sessionID] != nil { terminalHints[sessionID] = nil }
    }

    /// For tests: adds a session directly.
    func applyTestSession(_ session: Session) {
        try? state.workspace.addSession(session)
    }

    // MARK: - Notifications

    struct NotificationBaseline: Equatable {
        var status: SessionStatus
        var agentAlive: Bool
    }

    /// Compares sessions with the last check and posts notifications for real
    /// changes: → Awaiting Input, Working → Completed, and (optionally) a
    /// working agent that exited. The first check only records a baseline.
    public func checkNotifications() {
        let current = Dictionary(uniqueKeysWithValues: state.workspace.sessions.map {
            ($0.id, NotificationBaseline(status: $0.status, agentAlive: isAgentAlive($0.id)))
        })
        defer { notificationBaseline = current }
        guard let previous = notificationBaseline else { return }
        let settings = state.settings.notifications
        for session in state.workspace.sessions {
            guard let before = previous[session.id], let after = current[session.id], before != after else { continue }
            let kind: SessionNotification.Kind
            if after.status == .awaitingInput && before.status != .awaitingInput {
                guard settings.awaitingInput else { continue }
                kind = .awaitingInput
            } else if after.status == .completed && before.status == .working {
                guard settings.finished else { continue }
                kind = .finished
            } else if before.agentAlive && !after.agentAlive && after.status == .working {
                guard settings.stoppedUnexpectedly else { continue }
                kind = .stopped
            } else {
                continue
            }
            if appIsActive && isVisible(session.id) { continue }
            notifier?.post(notification(kind, for: session), sound: settings.sound)
        }
    }

    private func notification(_ kind: SessionNotification.Kind, for session: Session) -> SessionNotification {
        let project = state.workspace.project(session.projectID)?.name ?? ""
        let summary = session.summary.isEmpty ? nil : session.summary
        switch kind {
        case .awaitingInput:
            return SessionNotification(sessionID: session.id, kind: kind, title: "\(session.name) needs your input", subtitle: project,
                                       body: session.needsAction ?? summary ?? "Claude is waiting for you.")
        case .finished:
            return SessionNotification(sessionID: session.id, kind: kind, title: "\(session.name) finished", subtitle: project,
                                       body: summary ?? "Claude finished its turn.")
        case .stopped:
            return SessionNotification(sessionID: session.id, kind: kind, title: "\(session.name) stopped unexpectedly", subtitle: project,
                                       body: "The agent exited while it was working.")
        }
    }

    /// Whether the session is on screen: the selected tab, or a split pane.
    private func isVisible(_ sessionID: UUID) -> Bool {
        if selectedSessionID == sessionID { return true }
        guard state.settings.layout == .split, canSplit else { return false }
        return splitPanes(capacity: SplitLayout.maxPanes).contains { $0.id == sessionID }
    }

    /// Clicking a notification opens its session.
    public func openFromNotification(_ sessionID: UUID) {
        guard state.workspace.session(sessionID) != nil else { return }
        select(sessionID)
    }

    // MARK: - Menu

    public func updateMenuFlags() {
        var flags = MenuFlags()
        flags.hasProjects = !state.workspace.projects.isEmpty
        flags.canRunSessions = environment.canRunSessions
        if let id = selectedSessionID, state.workspace.session(id) != nil {
            flags.hasSelection = true
            flags.canResumeSelected = !running.contains(id)
            flags.canStopSelected = running.contains(id) || isAgentAlive(id)
        }
        if flags != menuFlags { menuFlags = flags }
    }

    // MARK: - Usage

    /// Status line settings for launched sessions: records plan usage for the
    /// app and still runs the user's own status line.
    private func statusLineCapture() -> StatusLineCapture? {
        guard let usageURL else { return nil }
        let userSettings = discovery.claudeHome.appendingPathComponent("settings.json")
        return StatusLineCapture(statusDirectory: statusDirectory?.path, usagePath: usageURL.path,
                                 userStatusLine: UserStatusLine.load(from: userSettings))
    }

    public func context(for sessionID: UUID) -> ContextUsage? {
        contexts[sessionID] ?? estimatedContexts[sessionID]
    }

    /// Re-reads usage and per-session status files that sessions' status lines
    /// have updated since the last poll.
    public func pollUsage() {
        let fileManager = FileManager.default
        if let usageURL,
           let modified = (try? fileManager.attributesOfItem(atPath: usageURL.path))?[.modificationDate] as? Date,
           modified != usageModified {
            usageModified = modified
            if let data = try? Data(contentsOf: usageURL), let snapshot = UsageSnapshot.parse(data, updatedAt: modified) {
                adopt(snapshot)
            }
        }
        guard let statusDirectory,
              let files = try? fileManager.contentsOfDirectory(at: statusDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  statusModified[file.lastPathComponent] != modified
            else { continue }
            statusModified[file.lastPathComponent] = modified
            if let data = try? Data(contentsOf: file), let context = ContextUsage.parse(data), contexts[id] != context {
                contexts[id] = context
            }
        }
    }

    /// Asks Claude Code for plan usage (`claude -p /usage`); no model call, so
    /// it works before any session has run.
    public func refreshUsage() async {
        guard environment.canRunSessionsOrUnchecked, let commands = agentCommands(reportErrors: false) else { return }
        let result = await run(commands.usage(), logOnlyChanges: true, changeKey: "usage")
        if result.exitCode == 0, let snapshot = UsageSnapshot.parseUsageCommand(result.output, updatedAt: now()) {
            adopt(snapshot)
        }
    }

    private func adopt(_ snapshot: UsageSnapshot) {
        guard usage.map({ snapshot.updatedAt >= $0.updatedAt }) ?? true else { return }
        var merged = snapshot
        if merged.subscriptionType == nil { merged.subscriptionType = usage?.subscriptionType }
        usage = merged
    }

    // MARK: - Settings

    public func setSidebarWidth(_ width: Double) {
        state.settings.sidebarWidth = AppSettings.clampSidebarWidth(width)
        save()
    }

    public func setLayout(_ layout: LayoutMode) {
        state.settings.layout = layout
        save()
    }

    public func updateSettings(_ settings: AppSettings) {
        state.settings = settings
        save()
    }

    // MARK: - Helpers

    /// Shows an error to the user and records it in the log.
    func report(_ message: String) {
        errorMessage = message
        log.append(.error, message)
    }

    @discardableResult
    private func attempt<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            report(AppModel.describe(error))
            return nil
        }
    }

    private func save() {
        do {
            try store.save(state)
        } catch {
            report("Couldn't save: \(AppModel.describe(error))")
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
