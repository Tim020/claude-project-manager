import Foundation

/// Which changes the Files Changed views show.
public enum ChangesScope: String, CaseIterable, Sendable {
    /// Files the session's own Edit/Write tool calls changed.
    case session
    /// A git diff of the session's working directory against the main branch.
    case base
}

/// What a session's pane shows: its terminal (or history), or the Changes view.
public enum PaneMode: Equatable, Sendable {
    case terminal, changes
}

public struct SessionChangeState: Equatable, Sendable {
    public var session: SessionChangesResult?
    public var git: Result<GitChangesResult, GitChangesError>?
    /// Diffs fetched from git, by path (cleared when the file list changes).
    public var gitDiffs: [String: FileDiff] = [:]
    public var updatedAt: Date?
    /// Where the changes were looked for (see `ChangesDirectory`).
    public var directory: String?
}

/// Parsed edit summaries per history file, reused while the file is
/// unchanged (history files can be many megabytes).
public final class EditLogCache: @unchecked Sendable {
    private struct Entry { var modified: Date; var size: Int; var summary: SessionEditLog.Summary }
    private var entries: [URL: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    /// The first baseline per file across all the given history files (the
    /// session's first, then its subagents'). The latest edit and working
    /// directory come from the session's own history when it has them.
    public func summary(files: [URL]) -> SessionEditLog.Summary {
        var seen = Set<String>()
        var merged = SessionEditLog.Summary()
        for file in files {
            let summary = summary(file: file)
            for baseline in summary.baselines where seen.insert(baseline.path).inserted {
                merged.baselines.append(baseline)
            }
            merged.lastEditPath = merged.lastEditPath ?? summary.lastEditPath
            merged.lastWorkingDirectory = merged.lastWorkingDirectory ?? summary.lastWorkingDirectory
        }
        return merged
    }

    public func baselines(files: [URL]) -> [SessionEditLog.Baseline] {
        summary(files: files).baselines
    }

    private func summary(file: URL) -> SessionEditLog.Summary {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast, size = values?.fileSize ?? -1
        if let entry = lock.withLock({ entries[file] }), entry.modified == modified, entry.size == size {
            return entry.summary
        }
        let parsed = SessionEditLog.summary(files: [file])
        lock.withLock { entries[file] = Entry(modified: modified, size: size, summary: parsed) }
        return parsed
    }
}

extension AppModel {
    // MARK: Reading

    public func changes(for sessionID: UUID, scope: ChangesScope) -> ChangeSet? {
        guard let state = sessionChanges[sessionID] else { return nil }
        switch scope {
        case .session: return state.session?.changes
        case .base: return try? state.git?.get().changes
        }
    }

    /// The changes the header and inspector show: the current scope.
    public func currentChanges(for sessionID: UUID) -> ChangeSet? {
        changes(for: sessionID, scope: changesScope)
    }

    /// "main", "dev"… for the "vs" button, never a guess: a branch just
    /// chosen, else the loaded one, else the one remembered from last time,
    /// else the project's choice, else "…" until it's known.
    public func baseName(for sessionID: UUID) -> String {
        if let pending = pendingBaseNames[sessionID] { return pending }
        if let loaded = try? sessionChanges[sessionID]?.git?.get().baseName { return loaded }
        let session = state.workspace.session(sessionID)
        if let remembered = session?.lastBaseName { return remembered }
        if let project = session.flatMap({ state.workspace.project($0.projectID) }), let chosen = project.comparisonBranch { return chosen }
        return "…"
    }

    /// Nothing loaded yet, or a newly chosen branch is still being compared:
    /// the lists show a spinner rather than stale data.
    public func isLoadingChanges(_ sessionID: UUID) -> Bool {
        sessionChanges[sessionID] == nil || pendingBaseNames[sessionID] != nil
    }

    /// Whether the change lists should show a spinner: nothing loaded yet,
    /// or "vs" is showing and a newly chosen branch is still being compared.
    public func showsChangesLoading(for sessionID: UUID) -> Bool {
        sessionChanges[sessionID] == nil || (changesScope == .base && pendingBaseNames[sessionID] != nil)
    }

    /// Where Files Changed looked for this session's changes: usually its own
    /// folder, or the worktree it's been working in.
    public func changesDirectory(for sessionID: UUID) -> String? {
        sessionChanges[sessionID]?.directory
    }

    /// Where the "vs" branch came from (pull request, project, default).
    public func baseSource(for sessionID: UUID) -> BaseSource? {
        try? sessionChanges[sessionID]?.git?.get().baseSource
    }

    /// Branches to offer as the project's comparison branch.
    public func branches(for sessionID: UUID) async -> [String] {
        guard let session = state.workspace.session(sessionID) else { return [] }
        return await GitChanges.branches(directory: session.workingDirectory, runner: changesRunner, git: gitExecutable)
    }

    /// The session's pull request via `gh pr view`, cached for a few minutes.
    /// Skipped when gh isn't installed or isn't signed in.
    func pullRequest(forDirectory directory: String) async -> GitHubCLI.PullRequest? {
        switch environment.githubCLI {
        case .notInstalled, .signedOut: return nil
        case .unchecked, .signedIn: break
        }
        guard let gh = locateGitHubCLI() else { return nil }
        if let cached = pullRequestCache[directory], now().timeIntervalSince(cached.checked) < AppModel.pullRequestCacheInterval {
            return cached.pullRequest
        }
        let output = await run(GitHubCLI.command(["pr", "view", "--json", GitHubCLI.pullRequestFields], in: directory, gh: gh),
                               logOnlyChanges: true, changeKey: "gh-pr|\(directory)")
        let pullRequest = output.exitCode == 0 ? GitHubCLI.parsePullRequest(output.output) : nil
        pullRequestCache[directory] = (pullRequest, now())
        return pullRequest
    }

    /// Why "vs main" can't be shown, if it can't.
    public func baseUnavailableReason(for sessionID: UUID) -> String? {
        guard case .failure(let error)? = sessionChanges[sessionID]?.git else { return nil }
        switch error {
        case .notARepository: return "This session's folder isn't in a git repository."
        case .noBaseBranch: return "No main or master branch to compare against."
        }
    }

    public func absolutePath(for sessionID: UUID, path: String, scope: ChangesScope) -> String? {
        guard let state = sessionChanges[sessionID] else { return nil }
        switch scope {
        case .session:
            return state.session?.absolutePaths[path]
        case .base:
            guard let result = try? state.git?.get(), let file = result.changes.files.first(where: { $0.path == path }) else { return nil }
            return result.absolutePath(for: file)
        }
    }

    /// A file's diff: computed with the file list for "This Session", fetched
    /// from git (then kept) for "vs main".
    public func diff(for sessionID: UUID, path: String, scope: ChangesScope) async -> FileDiff? {
        guard let state = sessionChanges[sessionID] else { return nil }
        switch scope {
        case .session:
            return state.session?.diffs[path]
        case .base:
            if let cached = state.gitDiffs[path] { return cached }
            guard let result = try? state.git?.get(), let file = result.changes.files.first(where: { $0.path == path }) else { return nil }
            let diff = await GitChanges.diff(for: file, in: result, runner: changesRunner, git: gitExecutable)
            if (try? sessionChanges[sessionID]?.git?.get()) == result { sessionChanges[sessionID]?.gitDiffs[path] = diff }
            return diff
        }
    }

    // MARK: Refreshing

    /// Re-reads both scopes for a session. If a refresh is already running it
    /// returns; one that finds the branch changed while it ran goes again.
    public func refreshChanges(for sessionID: UUID) async {
        guard !refreshingChanges.contains(sessionID) else { return }
        refreshingChanges.insert(sessionID)
        defer { refreshingChanges.remove(sessionID) }
        repeat {
            let token = pendingBaseTokens[sessionID]
            await loadChanges(for: sessionID)
            guard pendingBaseTokens[sessionID] == token else { continue } // chosen mid-way: again
            pendingBaseTokens[sessionID] = nil
            pendingBaseNames[sessionID] = nil
            break
        } while true
    }

    private func loadChanges(for sessionID: UUID) async {
        guard let session = state.workspace.session(sessionID) else { return }
        changesDirty.remove(sessionID)

        let recorded = session.workingDirectory
        let projectDirectory = state.workspace.project(session.projectID)?.path
        let files = session.claudeSessionID.map { discovery.editLogFiles(projectPath: recorded, claudeSessionID: $0) } ?? []
        let cache = editLogCache
        let (sessionResult, directory) = await Task.detached(priority: .utility) { () -> (SessionChangesResult, String) in
            let summary = cache.summary(files: files)
            let directory = ChangesDirectory.resolve(recorded: recorded, projectDirectory: projectDirectory,
                                                     lastWorkingDirectory: summary.lastWorkingDirectory,
                                                     lastEditPath: summary.lastEditPath,
                                                     exists: { FileManager.default.fileExists(atPath: $0) })
            let result = SessionChanges.compute(baselines: summary.baselines, workingDirectory: directory,
                                                projectDirectory: projectDirectory, read: SessionChanges.readFile)
            return (result, directory)
        }.value
        var preferred: [PreferredBase] = []
        if let pullRequest = await pullRequest(forDirectory: directory) {
            preferred.append(PreferredBase(branch: pullRequest.base, source: .pullRequest(pullRequest.number)))
        }
        if let branch = state.workspace.project(session.projectID)?.comparisonBranch {
            preferred.append(PreferredBase(branch: branch, source: .project))
        }
        let gitResult = await GitChanges.load(directory: directory, runner: changesRunner, git: gitExecutable, preferred: preferred)

        if case .success(let result) = gitResult { recordBaseName(result.baseName, for: sessionID) }
        var updated = sessionChanges[sessionID] ?? SessionChangeState()
        if updated.git != gitResult { updated.gitDiffs = [:] }
        updated.session = sessionResult
        updated.git = gitResult
        updated.directory = directory
        updated.updatedAt = now()
        if updated != sessionChanges[sessionID] { sessionChanges[sessionID] = updated }
    }

    /// Loads open tabs that haven't been loaded yet, one at a time, so
    /// switching to them shows their changes (and "vs" branch) straight away.
    public func preloadChanges() async {
        for session in tabs where sessionChanges[session.id] == nil {
            await refreshChanges(for: session.id)
        }
    }

    /// Refreshes the given sessions (the visible ones) if a hook reported a
    /// tool call since their last refresh, or they've never been loaded.
    public func refreshChangesIfNeeded(_ sessionIDs: [UUID]) async {
        for id in sessionIDs where changesDirty.contains(id) || sessionChanges[id] == nil {
            await refreshChanges(for: id)
        }
    }

    /// Sessions on screen: the selected tab, or the split panes.
    public var visibleSessionIDs: [UUID] {
        guard let selected = selectedSessionID else { return [] }
        return state.settings.layout == .split && canSplit ? tabs.map(\.id) : [selected]
    }

    func markChangesDirty(_ sessionID: UUID) {
        changesDirty.insert(sessionID)
    }

    // MARK: Views

    public var showsFilesInspector: Bool { state.settings.showFilesInspector }

    public func toggleFilesInspector() {
        var settings = state.settings
        settings.showFilesInspector.toggle()
        updateSettings(settings)
    }

    public func paneMode(for sessionID: UUID) -> PaneMode {
        paneModes[sessionID] ?? .terminal
    }

    public func setPaneMode(_ mode: PaneMode, for sessionID: UUID) {
        paneModes[sessionID] = mode == .terminal ? nil : mode
    }

    /// The file selected in the Changes view (the first, if none is).
    public func selectedChange(for sessionID: UUID) -> String? {
        let files = currentChanges(for: sessionID)?.files ?? []
        if let selected = selectedChanges[sessionID], files.contains(where: { $0.path == selected }) { return selected }
        return files.first?.path
    }

    public func selectChange(_ path: String, for sessionID: UUID) {
        selectedChanges[sessionID] = path
    }

    /// The inspector row whose diff preview is open, if any.
    public func expandedChange(for sessionID: UUID) -> String? {
        expandedChanges[sessionID]
    }

    public func toggleExpandedChange(_ path: String, for sessionID: UUID) {
        expandedChanges[sessionID] = expandedChanges[sessionID] == path ? nil : path
    }

    /// "Open Full Diff" in the inspector: the Changes view on that file.
    public func openFullDiff(_ path: String, for sessionID: UUID) {
        selectedChanges[sessionID] = path
        setPaneMode(.changes, for: sessionID)
    }
}
