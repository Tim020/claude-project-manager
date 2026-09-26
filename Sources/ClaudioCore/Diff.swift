import Foundation

// MARK: - Models

/// How a file changed, shown as a coloured letter (A/M/D/R) with the word on hover.
public enum FileChangeStatus: String, CaseIterable, Sendable {
    case added = "A", modified = "M", deleted = "D", renamed = "R"

    public var letter: String { rawValue }

    public var word: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }
}

public struct FileChange: Equatable, Sendable, Identifiable {
    /// Relative to the session's working directory (or repository root).
    public var path: String
    /// The previous path, for renames.
    public var oldPath: String?
    public var status: FileChangeStatus
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    /// An untracked folder, listed as one entry (like `git status`) rather
    /// than file by file; its contents aren't read. Its path ends in "/".
    public var isUntrackedFolder: Bool

    public init(path: String, oldPath: String? = nil, status: FileChangeStatus, additions: Int, deletions: Int,
                isBinary: Bool = false, isUntrackedFolder: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isUntrackedFolder = isUntrackedFolder
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent + (isUntrackedFolder ? "/" : "") }
    /// The containing directory, "" at the top level.
    public var directory: String {
        let trimmed = isUntrackedFolder ? String(path.dropLast()) : path
        let dir = (trimmed as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }
}

/// The files a session changed, in one scope.
public struct ChangeSet: Equatable, Sendable {
    public var files: [FileChange]

    public init(files: [FileChange]) {
        self.files = files
    }

    public static let empty = ChangeSet(files: [])

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    public var isEmpty: Bool { files.isEmpty }

    public func count(_ status: FileChangeStatus) -> Int {
        files.filter { $0.status == status }.count
    }

    public struct DirectoryGroup: Equatable, Sendable, Identifiable {
        public var directory: String
        public var files: [FileChange]
        public var id: String { directory }
    }

    /// Files grouped by directory, in order of first appearance.
    public var groupedByDirectory: [DirectoryGroup] {
        var order: [String] = []
        var groups: [String: [FileChange]] = [:]
        for file in files {
            if groups[file.directory] == nil { order.append(file.directory) }
            groups[file.directory, default: []].append(file)
        }
        return order.map { DirectoryGroup(directory: $0, files: groups[$0]!) }
    }
}

/// GitHub-style five-square bar: how much of a change is additions.
public enum ChangeBlocks {
    /// `true` for an added (green) square, `false` for a removed (red) one.
    public static func blocks(additions: Int, deletions: Int, count: Int = 5) -> [Bool] {
        let total = additions + deletions
        guard total > 0 else { return Array(repeating: false, count: count) }
        let green = Int((Double(count) * Double(additions) / Double(total)).rounded())
        return (0..<count).map { $0 < green }
    }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case hunk, context, added, removed }

    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

/// One file's diff: hunk headers and lines with old/new line numbers.
public struct FileDiff: Equatable, Sendable {
    public var lines: [DiffLine]
    public var isBinary: Bool

    public init(lines: [DiffLine], isBinary: Bool = false) {
        self.lines = lines
        self.isBinary = isBinary
    }

    public static let empty = FileDiff(lines: [])
    public static let binary = FileDiff(lines: [], isBinary: true)

    public var additions: Int { lines.filter { $0.kind == .added }.count }
    public var deletions: Int { lines.filter { $0.kind == .removed }.count }
}

// MARK: - Computing diffs

/// A line diff (Myers' algorithm) with unified-diff hunks, for comparing two
/// versions of a file when there's no git to ask.
public enum LineDiff {
    public static func diff(old: String?, new: String?, context: Int = 3) -> FileDiff {
        if (old?.contains("\u{0}") ?? false) || (new?.contains("\u{0}") ?? false) { return .binary }
        let a = lines(of: old), b = lines(of: new)
        return FileDiff(lines: hunks(edits: editScript(a, b), a: a, b: b, context: context))
    }

    static func lines(of text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    enum Edit: Equatable { case equal(Int, Int), delete(Int), insert(Int) }

    /// Myers' O((N+M)D) shortest edit script, after trimming the common prefix
    /// and suffix.
    static func editScript(_ a: [String], _ b: [String]) -> [Edit] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let x0 = prefix, n = a.count - prefix - suffix, m = b.count - prefix - suffix
        var middle: [Edit] = []
        if n == 0 {
            middle = (0..<m).map { .insert(x0 + $0) }
        } else if m == 0 {
            middle = (0..<n).map { .delete(x0 + $0) }
        } else {
            let max = n + m, offset = max
            var v = [Int](repeating: 0, count: 2 * max + 2)
            var trace: [[Int]] = []
            search: for d in 0...max {
                trace.append(v)
                for k in stride(from: -d, through: d, by: 2) {
                    var x: Int
                    if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                        x = v[offset + k + 1]
                    } else {
                        x = v[offset + k - 1] + 1
                    }
                    var y = x - k
                    while x < n, y < m, a[x0 + x] == b[x0 + y] { x += 1; y += 1 }
                    v[offset + k] = x
                    if x >= n && y >= m { break search }
                }
            }
            // Walk back through the trace.
            var x = n, y = m
            var reversed: [Edit] = []
            for d in stride(from: trace.count - 1, through: 0, by: -1) {
                let vd = trace[d]
                let k = x - y
                let prevK = (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) ? k + 1 : k - 1
                let prevX = d == 0 ? 0 : vd[offset + prevK]
                let prevY = prevX - prevK
                while x > prevX && y > prevY {
                    x -= 1; y -= 1
                    reversed.append(.equal(x0 + x, x0 + y))
                }
                if d > 0 {
                    if x == prevX { reversed.append(.insert(x0 + prevY)) } else { reversed.append(.delete(x0 + prevX)) }
                }
                x = prevX; y = prevY
            }
            middle = reversed.reversed()
        }

        return (0..<prefix).map { .equal($0, $0) } + middle
            + (0..<suffix).map { .equal(a.count - suffix + $0, b.count - suffix + $0) }
    }

    static func hunks(edits: [Edit], a: [String], b: [String], context: Int) -> [DiffLine] {
        let changed = edits.indices.filter { if case .equal = edits[$0] { return false } else { return true } }
        guard !changed.isEmpty else { return [] }

        // Ranges of edits to show: each change plus context, merged when close.
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(edits.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }

        var output: [DiffLine] = []
        for range in ranges {
            var body: [DiffLine] = []
            var oldStart: Int?, newStart: Int?
            var oldCount = 0, newCount = 0
            // Positions before the hunk, for empty sides ("-0,0").
            var oldBefore = 0, newBefore = 0
            for edit in edits[..<range.lowerBound] {
                switch edit {
                case .equal: oldBefore += 1; newBefore += 1
                case .delete: oldBefore += 1
                case .insert: newBefore += 1
                }
            }
            for edit in edits[range] {
                switch edit {
                case .equal(let i, let j):
                    oldStart = oldStart ?? i + 1; newStart = newStart ?? j + 1
                    oldCount += 1; newCount += 1
                    body.append(DiffLine(kind: .context, text: a[i], oldNumber: i + 1, newNumber: j + 1))
                case .delete(let i):
                    oldStart = oldStart ?? i + 1
                    oldCount += 1
                    body.append(DiffLine(kind: .removed, text: a[i], oldNumber: i + 1))
                case .insert(let j):
                    newStart = newStart ?? j + 1
                    newCount += 1
                    body.append(DiffLine(kind: .added, text: b[j], newNumber: j + 1))
                }
            }
            let oldHeader = oldCount == 0 ? "\(oldBefore),0" : "\(oldStart!),\(oldCount)"
            let newHeader = newCount == 0 ? "\(newBefore),0" : "\(newStart!),\(newCount)"
            output.append(DiffLine(kind: .hunk, text: "@@ -\(oldHeader) +\(newHeader) @@"))
            output += body
        }
        return output
    }
}

/// Parses `git diff` output for one file.
public enum UnifiedDiffParser {
    private static let header = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

    public static func parse(_ text: String) -> FileDiff {
        var lines: [DiffLine] = []
        var oldNumber = 0, newNumber = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") { return .binary }
            if line.hasPrefix("@@") {
                guard let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let old = Range(match.range(at: 1), in: line), let new = Range(match.range(at: 2), in: line)
                else { continue }
                oldNumber = Int(line[old]) ?? 0
                newNumber = Int(line[new]) ?? 0
                inHunk = true
                lines.append(DiffLine(kind: .hunk, text: line))
                continue
            }
            guard inHunk, let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case " ":
                lines.append(DiffLine(kind: .context, text: body, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1; newNumber += 1
            case "-":
                lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldNumber))
                oldNumber += 1
            case "+":
                lines.append(DiffLine(kind: .added, text: body, newNumber: newNumber))
                newNumber += 1
            case "\\":
                continue // "\ No newline at end of file"
            default:
                inHunk = false // the next file's header
            }
        }
        return FileDiff(lines: lines)
    }
}
