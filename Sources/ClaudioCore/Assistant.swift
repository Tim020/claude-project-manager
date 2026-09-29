import Foundation

// The Project Assistant's data (design 9a, `design/Project Assistant
// Backend.md`): per project, kept apart from `state.json` because it grows
// without limit. Notes are saved straight away, whoever writes them; notes
// the assistant or a session wrote can be undone. Plan items only change
// when you act (Promote, Attach, a status change).

/// Who wrote a note.
public enum NoteAuthor: String, Codable, CaseIterable, Sendable {
    /// You, from the capture box (⇧⌘N).
    case user
    /// The assistant. It will write notes with a session's follow-ups (build step 4).
    case assistant
    /// A Claude Code session. It will write notes with `claudio note`, from the
    /// bundled plugin (build step 3).
    case session
}

public struct ProjectNote: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var author: NoteAuthor
    /// The session it came from (a session or assistant note), or was linked
    /// to when you wrote it.
    public var sessionID: UUID?
    /// That session's name when the note was written, for when it's gone.
    public var sessionName: String?
    public var createdAt: Date
    /// The plan item it's attached to. The link lives only here: an item's
    /// notes are the notes that point at it.
    public var itemID: UUID?

    public init(id: UUID = UUID(), text: String, author: NoteAuthor, sessionID: UUID? = nil, sessionName: String? = nil,
                createdAt: Date, itemID: UUID? = nil) {
        self.id = id
        self.text = text
        self.author = author
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.createdAt = createdAt
        self.itemID = itemID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        // Strict: rewriting an unknown author as a known one would change the
        // note. A new author comes with a new `AssistantData.currentVersion`.
        author = try c.decode(NoteAuthor.self, forKey: .author)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        itemID = try c.decodeIfPresent(UUID.self, forKey: .itemID)
    }

    /// Notes you didn't write yourself can always be undone.
    public var canUndo: Bool { author != .user }
}

/// Where a plan item is, in the Plan list's order.
public enum PlanStatus: String, Codable, CaseIterable, Sendable {
    /// A session is working on it (from Start Session, build step 3).
    case inSession
    case planned
    case idea
    case done

    public var label: String {
        switch self {
        case .inSession: return "In Session"
        case .planned: return "Planned"
        case .idea: return "Idea"
        case .done: return "Done"
        }
    }

    /// The Plan list's group heading.
    public var groupTitle: String {
        switch self {
        case .inSession: return "IN SESSION"
        case .planned: return "PLANNED"
        case .idea: return "IDEAS"
        case .done: return "DONE"
        }
    }
}

public struct PlanItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var status: PlanStatus
    /// The folder its work belongs in (nil: the project's Unfiled).
    public var folderID: UUID?
    /// Its GitHub issue, "#23" (build step 6).
    public var issue: String?
    /// The session working on it (build step 3).
    public var sessionID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, status: PlanStatus, folderID: UUID? = nil, issue: String? = nil,
                sessionID: UUID? = nil, createdAt: Date) {
        self.id = id
        self.title = title
        self.status = status
        self.folderID = folderID
        self.issue = issue
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        // Strict, like a note's author: an unknown status isn't rewritten.
        status = try c.decode(PlanStatus.self, forKey: .status)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// How much the assistant does in a project (design 9a, Assistant Settings;
/// its UI comes in build step 5).
public enum AssistantMode: String, Codable, CaseIterable, Sendable {
    /// Also works in the background, such as checking a note you've just
    /// captured against the plan.
    case automatic
    /// Only when you ask (Promote…).
    case manual
    /// Notes and the plan by hand: no Claude calls.
    case off
}

/// One project's assistant data, saved as `assistant.json`.
///
/// Notes and items are decoded one by one. An entry that can't be read (a
/// hand edit, a cut-off write) is kept as it was, in `unreadableNotes` or
/// `unreadableItems`, and written back unchanged, so one bad entry doesn't
/// cost the rest. A file from a newer version is refused whole.
public struct AssistantData: Codable, Equatable, Sendable {
    /// 2: plan items, the project's mode, and per-entry decoding.
    public static let currentVersion = 2
    public var version = AssistantData.currentVersion
    /// Oldest first, as written.
    public var notes: [ProjectNote] = []
    /// Oldest first, as created.
    public var items: [PlanItem] = []
    public var mode = AssistantMode.automatic
    public var unreadableNotes: [JSONValue] = []
    public var unreadableItems: [JSONValue] = []

    public init(notes: [ProjectNote] = [], items: [PlanItem] = []) {
        self.notes = notes
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case version, notes, items, mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // A newer Claudio's file may hold data this one doesn't know about,
        // and saving would drop it. Refused, it's left alone (read-only) instead.
        guard version <= AssistantData.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "Saved by a newer Claudio (version \(version))")
        }
        (notes, unreadableNotes) = try AssistantData.decodeEach(ProjectNote.self, c, .notes)
        (items, unreadableItems) = try AssistantData.decodeEach(PlanItem.self, c, .items)
        mode = try c.decodeIfPresent(AssistantMode.self, forKey: .mode) ?? .automatic
        // Version 1 had notes only; what it lacks takes its default.
        version = AssistantData.currentVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AssistantData.currentVersion, forKey: .version)
        try c.encode(mode, forKey: .mode)
        var notesArray = c.nestedUnkeyedContainer(forKey: .notes)
        for note in notes { try notesArray.encode(note) }
        for raw in unreadableNotes { try notesArray.encode(raw) }
        var itemsArray = c.nestedUnkeyedContainer(forKey: .items)
        for item in items { try itemsArray.encode(item) }
        for raw in unreadableItems { try itemsArray.encode(raw) }
    }

    /// Decodes an array one entry at a time: the entries that read, and the
    /// ones that don't, as they were.
    private static func decodeEach<T: Decodable>(_ type: T.Type, _ c: KeyedDecodingContainer<CodingKeys>,
                                                 _ key: CodingKeys) throws -> ([T], [JSONValue]) {
        guard let raw = try c.decodeIfPresent([JSONValue].self, forKey: key) else { return ([], []) }
        var read: [T] = []
        var unread: [JSONValue] = []
        let encoder = JSONEncoder()
        let decoder = JSONFileStore.decoder
        for entry in raw {
            if let data = try? encoder.encode(entry), let value = try? decoder.decode(T.self, from: data) {
                read.append(value)
            } else {
                unread.append(entry)
            }
        }
        return (read, unread)
    }

    /// Entries that couldn't be read, for the panel to say so.
    public var unreadableCount: Int { unreadableNotes.count + unreadableItems.count }
}

/// One change to a project's assistant data, appended to `audit.jsonl`.
/// `before` and `after` hold the changed note, and `beforeItem` and
/// `afterItem` the changed plan item, so any change can be reversed.
public struct AuditEntry: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case noteAdded, noteDeleted, noteUndone
        /// Attached to a plan item, or detached from one.
        case noteChanged
        case itemAdded, itemChanged, itemDeleted
        /// An assistant call ran (`job` says which, and how it went). It
        /// changes nothing by itself.
        case jobRan
    }

    /// One assistant call, for the Assistant's Activity Log (build step 5).
    public struct Job: Codable, Equatable, Sendable {
        public var name: String
        public var model: String
        /// What it was about: a note's id, for a Promote check.
        public var subject: String
        public var succeeded: Bool
        /// Why it failed, in the panel's words.
        public var failure: String?
        public var durationMS: Int?
        /// API-equivalent price, as Claude Code reports it.
        public var costUSD: Double?

        public init(name: String, model: String, subject: String, succeeded: Bool, failure: String? = nil,
                    durationMS: Int? = nil, costUSD: Double? = nil) {
            self.name = name
            self.model = model
            self.subject = subject
            self.succeeded = succeeded
            self.failure = failure
            self.durationMS = durationMS
            self.costUSD = costUSD
        }
    }

    public var id: UUID
    public var at: Date
    public var actor: NoteAuthor
    public var action: Action
    public var before: ProjectNote?
    public var after: ProjectNote?
    public var beforeItem: PlanItem?
    public var afterItem: PlanItem?
    public var job: Job?
    /// What caused it: `ui`, a session's id, or `assistant` for a job.
    public var cause: String

    public init(id: UUID = UUID(), at: Date, actor: NoteAuthor, action: Action, before: ProjectNote? = nil,
                after: ProjectNote? = nil, beforeItem: PlanItem? = nil, afterItem: PlanItem? = nil, job: Job? = nil,
                cause: String) {
        self.job = job
        self.id = id
        self.at = at
        self.actor = actor
        self.action = action
        self.before = before
        self.after = after
        self.beforeItem = beforeItem
        self.afterItem = afterItem
        self.cause = cause
    }
}

public protocol AssistantStoring: AnyObject {
    func load(projectID: UUID) throws -> AssistantData
    func save(_ data: AssistantData, projectID: UUID) throws
    func appendAudit(_ entry: AuditEntry, projectID: UUID) throws
    /// Where a project's data is kept, for error messages (nil in memory).
    func location(projectID: UUID) -> String?
    /// The working directory for assistant calls: somewhere with no
    /// CLAUDE.md or project settings (nil: a temporary directory).
    func runsDirectory() -> URL?
}

extension AssistantStoring {
    public func location(projectID: UUID) -> String? { nil }
    public func runsDirectory() -> URL? { nil }
}

/// Keeps assistant data in memory: the default, so tests and previews never
/// touch the real files.
public final class MemoryAssistantStore: AssistantStoring {
    public var data: [UUID: AssistantData] = [:]
    public var audit: [UUID: [AuditEntry]] = [:]

    public init() {}

    public func load(projectID: UUID) throws -> AssistantData { data[projectID] ?? AssistantData() }
    public func save(_ data: AssistantData, projectID: UUID) throws { self.data[projectID] = data }
    public func appendAudit(_ entry: AuditEntry, projectID: UUID) throws { audit[projectID, default: []].append(entry) }
}

/// `<root>/<project id>/assistant.json` and `audit.jsonl`, by default under
/// `~/Library/Application Support/Claudio/assistant`. Projects are keyed by
/// id, not path: the notes belong to the project entry, so removing and
/// re-adding a project starts it afresh.
public final class AssistantFileStore: AssistantStoring {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        JSONFileStore.defaultURL.deletingLastPathComponent().appendingPathComponent("assistant")
    }

    public func directory(projectID: UUID) -> URL {
        root.appendingPathComponent(projectID.uuidString.lowercased())
    }

    public func location(projectID: UUID) -> String? {
        directory(projectID: projectID).appendingPathComponent("assistant.json").path
    }

    public func runsDirectory() -> URL? {
        root.appendingPathComponent("runs")
    }

    public func load(projectID: UUID) throws -> AssistantData {
        let url = directory(projectID: projectID).appendingPathComponent("assistant.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AssistantData() }
        return try JSONFileStore.decoder.decode(AssistantData.self, from: Data(contentsOf: url))
    }

    public func save(_ data: AssistantData, projectID: UUID) throws {
        let directory = directory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONFileStore.encoder.encode(data).write(to: directory.appendingPathComponent("assistant.json"), options: .atomic)
    }

    public func appendAudit(_ entry: AuditEntry, projectID: UUID) throws {
        let directory = directory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONFileStore.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let url = directory.appendingPathComponent("audit.jsonl")
        // Only a missing log is created; any other failure to open it is
        // thrown, so the log is never replaced.
        guard FileManager.default.fileExists(atPath: url.path) else {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // An earlier write that stopped part-way leaves no newline; start
            // a new line rather than join onto it.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }
}

/// Where the capture box's note goes: its project, and the session that was
/// focused when it opened. What's typed is kept apart, in
/// `AppModel.noteDraft`, so a keystroke only redraws the box.
public struct NoteCapture: Equatable, Sendable {
    public var projectID: UUID
    public var sessionID: UUID?

    public init(projectID: UUID, sessionID: UUID?) {
        self.projectID = projectID
        self.sessionID = sessionID
    }
}

/// A short confirmation shown at the foot of the window ("Saved to Notes").
public struct Toast: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var text: String

    public init(_ text: String) {
        self.text = text
    }
}

public enum NoteMeta {
    /// A note's meta line: "You · linked to Shell Follow Up · 3h",
    /// "Assistant · from Shell Terminal · 1h", or "Shell Follow Up · 2m"
    /// (a session's name is its author).
    public static func line(for note: ProjectNote, sessionName: String?, now: Date) -> String {
        let age = RelativeAge.string(from: note.createdAt, now: now)
        switch note.author {
        case .user:
            return (["You"] + (sessionName.map { ["linked to \($0)"] } ?? []) + [age]).joined(separator: " · ")
        case .assistant:
            return (["Assistant"] + (sessionName.map { ["from \($0)"] } ?? []) + [age]).joined(separator: " · ")
        case .session:
            return [sessionName ?? "A session", age].joined(separator: " · ")
        }
    }
}
