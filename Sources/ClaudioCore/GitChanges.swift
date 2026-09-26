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
    /// The commit diffs are taken against (the merge base).
    public var baseCommit: String
    /// Untracked files, which git can't diff against the base.
    public var untracked: Set<String>

    public func absolutePath(for file: FileChange) -> String {
        (root as NSString).appendingPathComponent(file.path)
    }
}

public enum GitChangesError: Error, Equatable, Sendable {
    case notARepository
    case noBaseBranch
}

public enum GitChanges {
    public static let defaultGit = "/usr/bin/git"

    public static func load(directory: String, runner: CommandRunning, git: String = defaultGit) async -> Result<GitChangesResult, GitChangesError> {
        func run(_ args: [String]) async -> CommandResult {
            await runner.run(command(args, in: directory, git: git))
        }
        let top = await run(["rev-parse", "--show-toplevel"])
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard top.exitCode == 0, !root.isEmpty else { return .failure(.notARepository) }

        guard let base = await baseBranch(run: run) else { return .failure(.noBaseBranch) }
        let mergeBase = await run(["merge-base", "HEAD", base])
        let baseCommit = mergeBase.exitCode == 0 ? mergeBase.output.trimmingCharacters(in: .whitespacesAndNewlines) : base

        // Paths are relative to the root whatever the working directory.
        func runAtRoot(_ args: [String]) async -> CommandResult {
            await runner.run(command(args, in: root, git: git))
        }
        let numstat = await runAtRoot(["diff", "-M", "-z", "--numstat", baseCommit])
        let nameStatus = await runAtRoot(["diff", "-M", "-z", "--name-status", baseCommit])
        var files = parse(numstat: numstat.output, nameStatus: nameStatus.output)

        let others = await runAtRoot(["ls-files", "--others", "--exclude-standard", "-z"])
        let untracked = others.output.split(separator: "\u{0}").map(String.init)
        for path in untracked {
            let text = SessionChanges.readFile((root as NSString).appendingPathComponent(path))
            let diff = (text?.utf8.count ?? 0) > SessionChanges.maxDiffBytes ? FileDiff.binary : LineDiff.diff(old: nil, new: text)
            files.append(FileChange(path: path, status: .added, additions: diff.additions, deletions: 0, isBinary: diff.isBinary))
        }
        return .success(GitChangesResult(changes: ChangeSet(files: files), root: root, baseName: displayName(ofBase: base),
                                         baseCommit: baseCommit, untracked: Set(untracked)))
    }

    /// One file's diff against the base (untracked files against nothing).
    public static func diff(for file: FileChange, in result: GitChangesResult, runner: CommandRunning, git: String = defaultGit) async -> FileDiff {
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
