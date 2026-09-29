import Foundation

// Step 3 of the Project Assistant (design 9a): what a session Claudio starts
// gets from the assistant. `--plugin-dir` loads Claudio's small plugin, whose
// `claudio` command reads the plan and writes notes back through an inbox
// file. `--add-dir` points at the project's approved skills. Both are fixed
// at launch, so they go on new sessions only (resuming an agent with flags
// makes a copy).

/// The assistant's launch flags for a new session.
public struct AssistantLaunch: Equatable, Sendable {
    /// Claudio's plugin, copied to Application Support (a stable path: it's
    /// saved in a background agent's respawn flags).
    public var pluginDirectory: String?
    /// The project's skills root. Its `.claude/skills` holds approved skills.
    public var skillsRoot: String?

    public init(pluginDirectory: String?, skillsRoot: String?) {
        self.pluginDirectory = pluginDirectory
        self.skillsRoot = skillsRoot
    }

    public var arguments: [String] {
        (pluginDirectory.map { ["--plugin-dir", $0] } ?? []) + (skillsRoot.map { ["--add-dir", $0] } ?? [])
    }

    public var isEmpty: Bool { pluginDirectory == nil && skillsRoot == nil }
}

/// Claudio's plugin for sessions: `bin/claudio` and the `/claudio:note`
/// skill. Kept here rather than in the app bundle, so it's tested on Linux
/// and works from `swift run`; it's written out to Application Support at
/// launch, whenever the files there differ.
public enum ClaudioPlugin {
    public struct File: Equatable, Sendable {
        public var path: String
        public var contents: String
        public var isExecutable: Bool
    }

    public static let files: [File] = [
        File(path: ".claude-plugin/plugin.json", contents: manifest, isExecutable: false),
        File(path: "bin/claudio", contents: command, isExecutable: true),
        File(path: "skills/note/SKILL.md", contents: noteSkill, isExecutable: false),
    ]

    /// Writes the plugin to `directory` unless it's already there as it
    /// should be. It's built in a folder beside it and then moved into place,
    /// so a session never sees half of it. True when it wrote.
    @discardableResult
    public static func install(at directory: URL) throws -> Bool {
        let manager = FileManager.default
        let current = files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.path)
            return (try? String(contentsOf: url, encoding: .utf8)) == file.contents
                && (!file.isExecutable || manager.isExecutableFile(atPath: url.path))
        }
        if current { return false }
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(directory.lastPathComponent)-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        for file in files {
            let url = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.contents.utf8).write(to: url)
            if file.isExecutable { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try manager.moveItem(at: staging, to: directory)
        return true
    }

    static let manifest = #"""
    {
      "name": "claudio",
      "version": "1.0.0",
      "description": "Lets sessions started by Claudio read the project's plan and save notes to it."
    }

    """#

    /// POSIX sh, so it needs nothing installed. It finds Claudio's data from
    /// its own location (`plugin/claudio/bin` → `assistant`), and its
    /// project from the working directory via `index.tsv` (the longest
    /// matching path, so a worktree finds its repository). A note is one
    /// appended line: session id, directory, command, base64 text.
    static let command = #"""
    #!/bin/sh
    # claudio: lets a Claude Code session started by Claudio read the project's
    # plan and save notes to it. Written by Claudio at launch; edits are replaced.

    here=$(cd "$(dirname "$0")" && pwd -P) || exit 1
    data="${CLAUDIO_ASSISTANT_DIR:-$here/../../../assistant}"
    tab=$(printf '\t')

    usage() {
      cat <<'EOF'
    usage:
      claudio plan              the project's plan, with each item's id
      claudio item <id>         one plan item and its notes
      claudio note "<text>"     save a note (the user can undo it)
      claudio note -            save a note read from standard input
    EOF
    }

    # The project id for the working directory, from index.tsv.
    project_id() {
      [ -f "$data/index.tsv" ] || return 0
      for dir in "$PWD" "$(pwd -P)"; do
        best=""
        bestlen=0
        while IFS="$tab" read -r path id; do
          [ -n "$path" ] || continue
          case "$dir/" in
            "$path"/*)
              if [ "${#path}" -gt "$bestlen" ]; then best=$id; bestlen=${#path}; fi ;;
          esac
        done < "$data/index.tsv"
        if [ -n "$best" ]; then
          printf '%s\n' "$best"
          return 0
        fi
      done
    }

    plan_file() {
      id=$(project_id)
      if [ -z "$id" ] || [ ! -f "$data/$id/plan.md" ]; then
        echo "claudio: Claudio has no plan for $PWD" >&2
        return 1
      fi
      printf '%s\n' "$data/$id/plan.md"
    }

    case "${1:-}" in
      plan)
        file=$(plan_file) || exit 1
        grep -v '^  ' "$file"
        ;;
      item)
        if [ -z "${2:-}" ]; then usage >&2; exit 2; fi
        file=$(plan_file) || exit 1
        awk -v id="$2" 'index($0, "- [" id "]") == 1 { on = 1; print; next }
                        on && /^  / { print; next }
                        { on = 0 }' "$file" | grep . \
          || { echo "claudio: no item $2 in the plan (see claudio plan)" >&2; exit 1; }
        ;;
      note)
        shift
        if [ "${1:-}" = "-" ]; then text=$(cat); else text="$*"; fi
        if [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then usage >&2; exit 2; fi
        session="${CLAUDE_CODE_SESSION_ID:-${CLAUDIO_SESSION_ID:-}}"
        encoded=$(printf '%s' "$text" | base64 | tr -d '\n')
        mkdir -p "$data" || exit 1
        printf '%s\t%s\tnote\t%s\n' "$session" "$PWD" "$encoded" >> "$data/inbox.log" || exit 1
        echo "Saved to the project's notes in Claudio."
        ;;
      help|-h|--help)
        usage
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac

    """#

    static let noteSkill = #"""
    ---
    name: note
    description: Save a note to this project's notebook in Claudio, the app that started this session, with the `claudio note` command. Use it for something worth keeping that isn't in the code, the git history, CLAUDE.md or memory, such as a decision and why it was made, a gotcha found the hard way, or follow-up work that's out of scope. Not for progress updates, and not every turn. `claudio plan` and `claudio item <id>` read the project's plan.
    ---

    # Claudio's notes and plan

    Claudio keeps a notebook and a plan for this project. The user reads notes in Claudio's Assistant panel, marked with this session's name, and can undo any note a session writes.

    These commands are on the Bash tool's PATH:

    - `claudio note "<text>"` saves a note straight away. For long text, pipe it in: `printf '%s' "…" | claudio note -`.
    - `claudio plan` prints the plan's items, grouped by status, each with an id.
    - `claudio item <id>` prints one item with its attached notes.

    When a note is worth writing:

    - It's something the user would want to find later, and couldn't get from the code, the git history, CLAUDE.md or your memory.
    - It's one or two plain sentences that make sense without this conversation.
    - It isn't a summary of what you did. The session's history already has that.
    - A session writes a few at most.

    Never edit Claudio's files yourself (the plan, the inbox, or anything under Claudio's Application Support folder). Use the commands.

    """#
}

/// `index.tsv`: each project's path and id, so `bin/claudio` can find its
/// project from the working directory.
public enum AssistantIndex {
    public static func text(projects: [Project]) -> String {
        projects.map { "\($0.path)\t\($0.id.uuidString.lowercased())\n" }.joined()
    }
}

/// `plan.md`: the read-only copy of a project's plan that `claudio plan`
/// and `claudio item` print. Item lines start with "- [id]"; the lines
/// under an item (its notes) are indented, so `claudio plan` can leave them out.
public enum PlanSnapshot {
    /// The id sessions use for an item: the first 8 characters of its UUID.
    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    public static func text(projectName: String, data: AssistantData, sessionName: (UUID) -> String?) -> String {
        var lines = ["# Plan for \(projectName)", "",
                     "Run `claudio item <id>` for an item and its notes. Only Claudio changes the plan."]
        let notesByItem = Dictionary(grouping: data.notes.filter { $0.itemID != nil }) { $0.itemID! }
        for status in PlanStatus.allCases {
            let items = data.items.filter { $0.status == status }
            guard !items.isEmpty else { continue }
            lines += ["", "## \(status.label)"]
            for item in items {
                let meta = [item.issue, item.sessionID.flatMap(sessionName)].compactMap { $0 }
                lines.append((["- [\(shortID(item.id))] \(item.title)"] + meta).joined(separator: " · "))
                for note in notesByItem[item.id] ?? [] {
                    let author: String
                    switch note.author {
                    case .user: author = "You"
                    case .assistant: author = "Assistant"
                    case .session: author = note.sessionID.flatMap(sessionName) ?? note.sessionName ?? "A session"
                    }
                    let body = note.text.split(separator: "\n", omittingEmptySubsequences: false)
                    lines.append("  - \(author): \(body.first ?? "")")
                    lines += body.dropFirst().map { "    \($0)" }
                }
            }
        }
        if data.items.isEmpty { lines += ["", "The plan is empty."] }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A line `bin/claudio` appended to `inbox.log`.
public struct InboxEntry: Equatable, Sendable {
    /// `CLAUDE_CODE_SESSION_ID` (a background agent's conversation id), or
    /// `CLAUDIO_SESSION_ID` (the app's session id, set for direct tabs). Empty
    /// when neither was set.
    public var sessionID: String
    /// Where the command ran.
    public var directory: String
    public var command: String
    public var text: String

    public init(sessionID: String, directory: String, command: String, text: String) {
        self.sessionID = sessionID
        self.directory = directory
        self.command = command
        self.text = text
    }

    /// "<session>\t<directory>\t<command>\t<base64 text>".
    public static func parse(_ line: String) -> InboxEntry? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, !fields[2].isEmpty,
              let data = Data(base64Encoded: fields[3]), let text = String(data: data, encoding: .utf8)
        else { return nil }
        return InboxEntry(sessionID: fields[0], directory: fields[1], command: fields[2], text: text)
    }
}

/// Reads `inbox.log` from where the last read stopped. The position is
/// saved beside it, so notes written while Claudio was closed are read at
/// the next launch, and none is read twice. Only whole lines are taken.
public struct InboxReader {
    public let url: URL
    public var offsetURL: URL { url.deletingLastPathComponent().appendingPathComponent("inbox.offset") }

    public init(url: URL) {
        self.url = url
    }

    public func take() -> [String] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        else { return [] }
        var offset = (try? String(contentsOf: offsetURL, encoding: .utf8))
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        // Replaced or cut short: start again from the top.
        if offset > size { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: 0x0A)
        else { return [] }
        let complete = data[data.startIndex...lastNewline]
        try? String(offset + UInt64(complete.count)).write(to: offsetURL, atomically: true, encoding: .utf8)
        return String(decoding: complete, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
