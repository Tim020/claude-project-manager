import Foundation

/// "vs main": everything that differs between a session's working directory
/// (or worktree) and where it branched from the repository's main branch —
/// committed, uncommitted and untracked.
public struct GitChangesResult: Equatable, Sendable {
    public var changes: ChangeSet
    /// The repository root; change paths are relative to it.
    public var root: String
    /// The base branch as shown ("main").
    public var baseName: String
    /// Where the base branch came from.
    public var baseSource: BaseSource
    /// The commit diffs are taken against (the merge base).
    public var baseCommit: String
    /// Untracked files, which git can't diff against the base.
    public var untracked: Set<String>

    public func absolutePath(for file: FileChange) -> String {
        (root as NSString).appendingPathComponent(file.path)
    }
}

/// Why a branch was chosen to compare against.
public enum BaseSource: Equatable, Sendable {
    /// The base branch of the session's open pull request (via gh).
    case pullRequest(Int)
    /// The branch chosen for the project.
    case project
    /// The repository's default branch (origin/HEAD, main or master).
    case repositoryDefault

    public var explanation: String {
        switch self {
        case .pullRequest(let number): return "the base branch of pull request #\(number)"
        case .project: return "the branch chosen for this project"
        case .repositoryDefault: return "the repository's default branch"
        }
    }
}

/// A branch to try as the base, in order of preference.
public struct PreferredBase: Equatable, Sendable {
    public var branch: String
    public var source: BaseSource

    public init(branch: String, source: BaseSource) {
        self.branch = branch
        self.source = source
    }
}

public enum GitChangesError: Error, Equatable, Sendable {
    case notARepository
    case noBaseBranch
}

public enum GitChanges {
    public static let defaultGit = "/usr/bin/git"

    public static func load(directory: String, runner: CommandRunning, git: String = defaultGit,
                            preferred: [PreferredBase] = []) async -> Result<GitChangesResult, GitChangesError> {
        func run(_ args: [String]) async -> CommandResult {
            await runner.run(command(args, in: directory, git: git))
        }
        let top = await run(["rev-parse", "--show-toplevel"])
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard top.exitCode == 0, !root.isEmpty else { return .failure(.notARepository) }

        var chosen: (branch: String, source: BaseSource)?
        for candidate in preferred {
            // Prefer the remote branch (what a PR targets), then a local one.
            for name in ["origin/\(candidate.branch)", candidate.branch]
            where await run(["rev-parse", "--verify", "--quiet", name + "^{commit}"]).exitCode == 0 {
                chosen = (name, candidate.source)
                break
            }
            if chosen != nil { break }
        }
        if chosen == nil, let fallback = await baseBranch(run: run) { chosen = (fallback, .repositoryDefault) }
        guard let (base, baseSource) = chosen else { return .failure(.noBaseBranch) }
        let mergeBase = await run(["merge-base", "HEAD", base])
        let baseCommit = mergeBase.exitCode == 0 ? mergeBase.output.trimmingCharacters(in: .whitespacesAndNewlines) : base

        // Paths are relative to the root whatever the working directory.
        func runAtRoot(_ args: [String]) async -> CommandResult {
            await runner.run(command(args, in: root, git: git))
        }
        let numstat = await runAtRoot(["diff", "-M", "-z", "--numstat", baseCommit])
        let nameStatus = await runAtRoot(["diff", "-M", "-z", "--name-status", baseCommit])
        var files = parse(numstat: numstat.output, nameStatus: nameStatus.output)

        // Untracked, not ignored. --directory lists a wholly untracked folder
        // as one "dir/" entry, as git status does, instead of every file in it
        // (a leftover node_modules can hold tens of thousands).
        let others = await runAtRoot(["ls-files", "--others", "--exclude-standard", "--directory", "--no-empty-directory", "-z"])
        let untracked = others.output.split(separator: "\u{0}").map(String.init)
        for path in untracked {
            if path.hasSuffix("/") {
                files.append(FileChange(path: path, status: .added, additions: 0, deletions: 0, isUntrackedFolder: true))
                continue
            }
            let text = SessionChanges.readFile((root as NSString).appendingPathComponent(path))
            let diff = (text?.utf8.count ?? 0) > SessionChanges.maxDiffBytes ? FileDiff.binary : LineDiff.diff(old: nil, new: text)
            files.append(FileChange(path: path, status: .added, additions: diff.additions, deletions: 0, isBinary: diff.isBinary))
        }
        return .success(GitChangesResult(changes: ChangeSet(files: files), root: root, baseName: displayName(ofBase: base),
                                         baseSource: baseSource, baseCommit: baseCommit, untracked: Set(untracked)))
    }

    /// Local and remote branch names (remote ones without "origin/"), for
    /// choosing a project's base branch.
    public static func branches(directory: String, runner: CommandRunning, git: String = defaultGit) async -> [String] {
        let output = await runner.run(command(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes/origin"],
                                              in: directory, git: git))
        guard output.exitCode == 0 else { return [] }
        let names = output.output.split(separator: "\n").map(String.init)
            .filter { $0 != "origin/HEAD" && $0 != "origin" }
            .map(displayName(ofBase:))
        return Array(Set(names)).sorted()
    }

    /// One file's diff against the base (untracked files against nothing).
    public static func diff(for file: FileChange, in result: GitChangesResult, runner: CommandRunning, git: String = defaultGit) async -> FileDiff {
        if file.isUntrackedFolder { return .empty }
        if result.untracked.contains(file.path) {
            let text = SessionChanges.readFile(result.absolutePath(for: file))
            return (text?.utf8.count ?? 0) > SessionChanges.maxDiffBytes ? .binary : LineDiff.diff(old: nil, new: text)
        }
        let paths = [file.oldPath, file.path].compactMap { $0 }
        let output = await runner.run(command(["diff", "-M", result.baseCommit, "--"] + paths, in: result.root, git: git))
        return UnifiedDiffParser.parse(output.output)
    }

    /// `origin/HEAD` if the remote has one, else a local or remote main/master.
    static func baseBranch(run: ([String]) async -> CommandResult) async -> String? {
        let remoteHead = await run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        let name = remoteHead.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteHead.exitCode == 0, !name.isEmpty { return name }
        for candidate in ["main", "master", "origin/main", "origin/master"] {
            if await run(["rev-parse", "--verify", "--quiet", candidate + "^{commit}"]).exitCode == 0 { return candidate }
        }
        return nil
    }

    public static func displayName(ofBase base: String) -> String {
        base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base
    }

    /// Merges `git diff -z --numstat` (counts) with `--name-status` (status).
    static func parse(numstat: String, nameStatus: String) -> [FileChange] {
        // --name-status -z: "M\0path\0", "R087\0old\0new\0".
        var statuses: [String: (FileChangeStatus, String?)] = [:]
        var order: [String] = []
        var fields = nameStatus.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)[...]
        while let code = fields.popFirst(), !code.isEmpty {
            let letter = code.first!
            if letter == "R" || letter == "C" {
                guard let old = fields.popFirst(), let new = fields.popFirst() else { break }
                statuses[new] = (letter == "R" ? .renamed : .added, letter == "R" ? old : nil)
                order.append(new)
            } else {
                guard let path = fields.popFirst() else { break }
                let status: FileChangeStatus = letter == "A" ? .added : letter == "D" ? .deleted : .modified
                statuses[path] = (status, nil)
                order.append(path)
            }
        }

        // --numstat -z: "a\td\tpath\0", or "a\td\t\0old\0new\0" for renames; "-\t-" when binary.
        var counts: [String: (Int, Int, Bool)] = [:]
        var parts = numstat.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)[...]
        while let entry = parts.popFirst(), !entry.isEmpty {
            let columns = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3 else { continue }
            var path = columns[2]
            if path.isEmpty {
                _ = parts.popFirst()
                path = parts.popFirst() ?? ""
            }
            let binary = columns[0] == "-"
            counts[path] = (Int(columns[0]) ?? 0, Int(columns[1]) ?? 0, binary)
        }

        return order.map { path in
            let (status, old) = statuses[path]!
            let (added, deleted, binary) = counts[path] ?? (0, 0, false)
            return FileChange(path: path, oldPath: old, status: status, additions: added, deletions: deleted, isBinary: binary)
        }
    }

    static func command(_ args: [String], in directory: String, git: String) -> TerminalLaunch {
        var environment = ProcessInfo.processInfo.environment
        // Read-only: don't take the index lock while Claude may be committing.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        return TerminalLaunch(executable: git, arguments: ["-C", directory] + args, environment: environment, workingDirectory: directory,
                              claudeArguments: [], label: (["git"] + args).joined(separator: " "))
    }
}
