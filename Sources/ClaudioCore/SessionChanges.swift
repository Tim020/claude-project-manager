import Foundation

/// The files a session edited, from the Edit/Write results in its history:
/// each records `filePath` and `originalFile` (null when the file was created).
public enum SessionEditLog {
    public struct Baseline: Equatable, Sendable {
        public var path: String
        /// The file's content before the session first edited it; nil if the
        /// session created it.
        public var original: String?

        public init(path: String, original: String?) {
            self.path = path
            self.original = original
        }
    }

    /// A file's latest edit, with the record's ISO 8601 timestamp.
    public struct Edit: Equatable, Sendable {
        public var path: String
        public var timestamp: String?

        public init(path: String, timestamp: String? = nil) {
            self.path = path
            self.timestamp = timestamp
        }
    }

    /// What a history file says about the session's edits.
    public struct Summary: Equatable, Sendable {
        public var baselines: [Baseline] = []
        /// Each edited file's latest edit, oldest first.
        public var edits: [Edit] = []
        /// The last working directory recorded (every message carries `cwd`;
        /// it follows `cd` and entering a worktree).
        public var lastWorkingDirectory: String?

        public init(baselines: [Baseline] = [], edits: [Edit] = [], lastWorkingDirectory: String? = nil) {
            self.baselines = baselines
            self.edits = edits
            self.lastWorkingDirectory = lastWorkingDirectory
        }

        /// The file edited most recently.
        public var lastEditPath: String? { edits.last?.path }

        /// Edited paths, most recent first, across several histories (a
        /// session's and its subagents'), ordered by timestamp. Edits without
        /// one count as oldest; ties keep their order.
        public static func pathsNewestFirst(_ edits: [Edit]) -> [String] {
            edits.enumerated()
                .sorted { ($0.element.timestamp ?? "", $0.offset) > ($1.element.timestamp ?? "", $1.offset) }
                .map(\.element.path)
        }
    }

    public static func summary(lines: [String]) -> Summary {
        var seen = Set<String>()
        var summary = Summary()
        for line in lines {
            let isEdit = line.contains("\"toolUseResult\"") && line.contains("\"filePath\"")
            guard isEdit || line.contains("\"cwd\""),
                  let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            else { continue }
            if let cwd = record["cwd"]?.stringValue, !cwd.isEmpty { summary.lastWorkingDirectory = cwd }
            guard isEdit, let tool = record["toolUseResult"], let path = tool["filePath"]?.stringValue, isEditResult(tool) else { continue }
            summary.edits.removeAll { $0.path == path }
            summary.edits.append(Edit(path: path, timestamp: record["timestamp"]?.stringValue))
            guard seen.insert(path).inserted else { continue }
            let original = tool["type"]?.stringValue == "create" ? nil : tool["originalFile"]?.stringValue
            summary.baselines.append(Baseline(path: path, original: original))
        }
        return summary
    }

    /// The first baseline for each file, in the order the session touched them.
    public static func baselines(lines: [String]) -> [Baseline] {
        summary(lines: lines).baselines
    }

    public static func summary(files: [URL]) -> Summary {
        summary(lines: files.flatMap { file -> [String] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        })
    }

    public static func baselines(files: [URL]) -> [Baseline] {
        summary(files: files).baselines
    }

    /// Edit/MultiEdit results carry `structuredPatch`/`oldString`; Write
    /// results carry `type` "create" or "update".
    private static func isEditResult(_ tool: JSONValue) -> Bool {
        if tool["structuredPatch"] != nil || tool["oldString"] != nil { return true }
        if let type = tool["type"]?.stringValue { return type == "create" || type == "update" }
        return false
    }
}

public struct SessionChangesResult: Equatable, Sendable {
    public var changes: ChangeSet
    /// Diffs keyed by the change's display path.
    public var diffs: [String: FileDiff]
    /// Absolute paths keyed by display path, for Open in Editor / Reveal.
    public var absolutePaths: [String: String]

    public static let empty = SessionChangesResult(changes: .empty, diffs: [:], absolutePaths: [:])
}

/// Compares each file as the session first found it with what's on disk now.
public enum SessionChanges {
    /// Files larger than this are listed without a diff.
    public static let maxDiffBytes = 1_000_000

    /// Only files in the session's folder (or its project's, apart from other
    /// sessions' worktrees) count: not Claude Code's own files under
    /// `~/.claude`, scratch files in /tmp, and so on.
    public static func compute(baselines: [SessionEditLog.Baseline], workingDirectory: String, projectDirectory: String? = nil,
                               read: (String) -> String?) -> SessionChangesResult {
        let work = standardized(workingDirectory)
        let project = projectDirectory.map(standardized)
        func isIncluded(_ path: String) -> Bool {
            if isWithin(path, work) { return true }
            guard let project, isWithin(path, project) else { return false }
            // Another session's worktree inside the project.
            return !isWithin(path, project + "/.claude/worktrees")
        }

        var files: [FileChange] = []
        var diffs: [String: FileDiff] = [:]
        var absolute: [String: String] = [:]
        for var baseline in baselines {
            baseline.path = standardized(baseline.path)
            guard isIncluded(baseline.path) else { continue }
            let current = read(baseline.path)
            let status: FileChangeStatus
            switch (baseline.original, current) {
            case (nil, nil): continue
            case (nil, _?): status = .added
            case (_?, nil): status = .deleted
            case let (old?, new?):
                if old == new { continue }
                status = .modified
            }
            let path = relativePath(baseline.path, to: work)
            let tooLarge = (baseline.original?.utf8.count ?? 0) > maxDiffBytes || (current?.utf8.count ?? 0) > maxDiffBytes
            let diff = tooLarge ? FileDiff.binary : LineDiff.diff(old: baseline.original, new: current)
            files.append(FileChange(path: path, status: status, additions: diff.additions, deletions: diff.deletions, isBinary: diff.isBinary))
            diffs[path] = diff
            absolute[path] = baseline.path
        }
        return SessionChangesResult(changes: ChangeSet(files: files), diffs: diffs, absolutePaths: absolute)
    }

    /// Reads a text file, or nil if it's missing.
    @Sendable public static func readFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// `path` is `directory` or inside it (not just sharing a prefix).
    static func isWithin(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    static func relativePath(_ path: String, to directory: String) -> String {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// Where a session is actually working, for Files Changed. It can differ from
/// the folder it started in: Claude may enter a worktree mid-session, or work
/// in one through a subagent.
public enum ChangesDirectory {
    /// Goes by the most recent edit inside the project (`recentEdits` is
    /// newest first; edits in /tmp, `~/.claude` and so on are skipped): its
    /// worktree if it's in one that still exists. Otherwise the last recorded
    /// working directory if it's in the project, else the folder the session
    /// started in.
    public static func resolve(recorded: String, projectDirectory: String?, lastWorkingDirectory: String?, recentEdits: [String],
                               exists: (String) -> Bool) -> String {
        let recordedPath = SessionChanges.standardized(recorded)
        let project = SessionChanges.standardized(projectDirectory ?? recorded)
        let inProject = recentEdits.lazy.map(SessionChanges.standardized).filter {
            SessionChanges.isWithin($0, project) || SessionChanges.isWithin($0, recordedPath)
        }
        for edit in inProject {
            guard let worktree = worktreeRoot(containing: edit) else { break }
            if SessionChanges.isWithin(worktree, project), exists(worktree) { return worktree }
        }
        if let cwd = lastWorkingDirectory.map(SessionChanges.standardized),
           SessionChanges.isWithin(cwd, project) || SessionChanges.isWithin(cwd, recordedPath), exists(cwd) {
            return cwd
        }
        return recorded
    }

    /// `<repo>/.claude/worktrees/<name>` for a path inside it.
    static func worktreeRoot(containing path: String) -> String? {
        guard let range = path.range(of: Worktree.marker) else { return nil }
        let rest = path[range.upperBound...]
        guard let name = rest.split(separator: "/").first else { return nil }
        return String(path[..<range.upperBound]) + name
    }
}

extension SessionDiscovery {
    /// A session's history file plus its subagents' (`<session>/subagents/*.jsonl`).
    public func editLogFiles(projectPath: String, claudeSessionID: String) -> [URL] {
        let main = historyFile(projectPath: projectPath, claudeSessionID: claudeSessionID)
        var files = FileManager.default.fileExists(atPath: main.path) ? [main] : []
        let subagents = main.deletingPathExtension().appendingPathComponent("subagents")
        let extra = (try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? []
        files += extra.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files
    }
}
