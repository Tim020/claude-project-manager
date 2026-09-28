import Foundation

/// One of the user's own shells (a login shell, not Claude), shown in the
/// Shell panel under the panes. Shells aren't sessions: they aren't saved,
/// and stay out of the sidebar and the status counts.
public struct ShellTab: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Where the shell started.
    public var workingDirectory: String
    /// The start directory's git branch, if it's in a repository.
    public var branch: String?

    public init(id: UUID = UUID(), workingDirectory: String, branch: String? = nil) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.branch = branch
    }

    /// The tab's label: the start directory's name.
    public var name: String {
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty ? workingDirectory : name
    }
}

/// The Shell panel (design 7a): one tool window under all panes, with its own
/// tabs. It stays as it is while you switch sessions.
public struct ShellPanel: Equatable, Sendable {
    public private(set) var tabs: [ShellTab] = []
    public private(set) var selectedID: UUID?
    /// Shown under the panes. Hiding it keeps the shells running.
    public var isVisible = false
    /// Fills the detail area, hiding the panes.
    public var isMaximised = false

    public init() {}

    /// Whether the panel is showing: it has shells and hasn't been hidden.
    public var isOpen: Bool { isVisible && !tabs.isEmpty }

    public var selectedTab: ShellTab? {
        tabs.first { $0.id == selectedID }
    }

    /// Adds a shell after the others, selects it and shows the panel.
    public mutating func add(_ tab: ShellTab) {
        tabs.append(tab)
        selectedID = tab.id
        isVisible = true
    }

    public mutating func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Removes a shell. Closing the selected one selects its right-hand
    /// neighbour (or the new last one); closing the last one hides the panel.
    /// Returns false if there was no such shell (it may have closed already).
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty {
            isVisible = false
            isMaximised = false
        }
        return true
    }
}

extension TerminalLaunch {
    /// The user's login shell (`$SHELL -l`), started in `workingDirectory`.
    public static func loginShell(_ shell: String, workingDirectory: String,
                                  baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalLaunch {
        var environment = baseEnvironment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Claudio"
        if environment["LANG"]?.isEmpty ?? true { environment["LANG"] = "en_US.UTF-8" }
        // Claudio's own session variable would mislead tools run here.
        environment["CLAUDIO_SESSION_ID"] = nil
        return TerminalLaunch(executable: shell, arguments: ["-l"], environment: environment,
                              workingDirectory: workingDirectory, claudeArguments: [], label: "\(shell) -l")
    }
}

/// What a terminal's process ended with. SwiftTerm reports the raw
/// `waitpid` status (SwiftTerm 1.20.0, `LocalProcess.processTerminated`),
/// so `exit 127` arrives as 32512.
public enum ProcessExitStatus {
    /// The exit code for a raw `waitpid` status, the way shells report it:
    /// the process's own code, or 128 + the signal that killed it.
    public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}

/// Reads a directory's git branch straight from `.git/HEAD`, without running
/// git (a worktree's `.git` is a file naming its git directory).
public enum GitHead {
    /// The branch checked out at `directory` (or the short commit when
    /// detached), or nil outside a repository.
    public static func branch(atDirectory directory: String, fileManager: FileManager = .default) -> String? {
        var path = (directory as NSString).standardizingPath
        while true {
            let dotGit = (path as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                let gitDirectory = isDirectory.boolValue ? dotGit : linkedGitDirectory(dotGit, relativeTo: path)
                guard let gitDirectory,
                      let head = try? String(contentsOfFile: (gitDirectory as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                return branch(fromHead: head)
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            path = parent
        }
    }

    /// `ref: refs/heads/main` → "main"; a detached commit → its first 7 characters.
    static func branch(fromHead head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return line.isEmpty ? nil : String(line.prefix(7))
    }

    /// A worktree's `.git` file: `gitdir: <path>`.
    private static func linkedGitDirectory(_ file: String, relativeTo directory: String) -> String? {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : (directory as NSString).appendingPathComponent(target)
    }
}
