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
}

/// Parsed Edit/Write baselines per history file, reused while the file is
/// unchanged (history files can be many megabytes).
public final class EditLogCache: @unchecked Sendable {
    private struct Entry { var modified: Date; var size: Int; var baselines: [SessionEditLog.Baseline] }
    private var entries: [URL: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    /// The first baseline per file across all the given history files.
    public func baselines(files: [URL]) -> [SessionEditLog.Baseline] {
        var seen = Set<String>()
        var merged: [SessionEditLog.Baseline] = []
        for file in files {
            for baseline in baselines(file: file) where seen.insert(baseline.path).inserted {
                merged.append(baseline)
            }
        }
        return merged
    }

    private func baselines(file: URL) -> [SessionEditLog.Baseline] {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast, size = values?.fileSize ?? -1
        if let entry = lock.withLock({ entries[file] }), entry.modified == modified, entry.size == size {
            return entry.baselines
        }
        let parsed = SessionEditLog.baselines(files: [file])
        lock.withLock { entries[file] = Entry(modified: modified, size: size, baselines: parsed) }
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

    /// "main", "master"… for the "vs main" button.
    public func baseName(for sessionID: UUID) -> String {
        (try? sessionChanges[sessionID]?.git?.get().baseName) ?? "main"
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

    /// Re-reads both scopes for a session. Skipped if a refresh is running.
    public func refreshChanges(for sessionID: UUID) async {
        guard let session = state.workspace.session(sessionID), !refreshingChanges.contains(sessionID) else { return }
        refreshingChanges.insert(sessionID)
        defer { refreshingChanges.remove(sessionID) }
        changesDirty.remove(sessionID)

        let directory = session.workingDirectory
        let files = session.claudeSessionID.map { discovery.editLogFiles(projectPath: directory, claudeSessionID: $0) } ?? []
        let cache = editLogCache
        let sessionResult = await Task.detached(priority: .utility) {
            SessionChanges.compute(baselines: cache.baselines(files: files), workingDirectory: directory, read: SessionChanges.readFile)
        }.value
        var preferred: [PreferredBase] = []
        if let pullRequest = await pullRequest(forDirectory: directory) {
            preferred.append(PreferredBase(branch: pullRequest.base, source: .pullRequest(pullRequest.number)))
        }
        if let branch = state.workspace.project(session.projectID)?.comparisonBranch {
            preferred.append(PreferredBase(branch: branch, source: .project))
        }
        let gitResult = await GitChanges.load(directory: directory, runner: changesRunner, git: gitExecutable, preferred: preferred)

        var updated = sessionChanges[sessionID] ?? SessionChangeState()
        if updated.git != gitResult { updated.gitDiffs = [:] }
        updated.session = sessionResult
        updated.git = gitResult
        updated.updatedAt = now()
        if updated != sessionChanges[sessionID] { sessionChanges[sessionID] = updated }
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
