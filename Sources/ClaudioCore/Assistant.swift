import Foundation

// The Project Assistant's data (design 9a, `design/Project Assistant
// Backend.md`): per project, kept apart from `state.json` because it grows
// without limit. Notes are saved straight away, whoever writes them; notes
// the assistant or a session wrote can be undone.

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

    public init(id: UUID = UUID(), text: String, author: NoteAuthor, sessionID: UUID? = nil, sessionName: String? = nil,
                createdAt: Date) {
        self.id = id
        self.text = text
        self.author = author
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.createdAt = createdAt
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
    }

    /// Notes you didn't write yourself can always be undone.
    public var canUndo: Bool { author != .user }
}

/// One project's assistant data, saved as `assistant.json`.
public struct AssistantData: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = AssistantData.currentVersion
    /// Oldest first, as written.
    public var notes: [ProjectNote] = []

    public init(notes: [ProjectNote] = []) {
        self.notes = notes
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
        notes = try c.decodeIfPresent([ProjectNote].self, forKey: .notes) ?? []
        // Migrations from older versions go here, switching on `version`.
        version = AssistantData.currentVersion
    }
}

/// One change to a project's assistant data, appended to `audit.jsonl`.
/// `before` and `after` hold the changed note, so any change can be reversed.
public struct AuditEntry: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case noteAdded, noteDeleted, noteUndone
    }

    public var id: UUID
    public var at: Date
    public var actor: NoteAuthor
    public var action: Action
    public var before: ProjectNote?
    public var after: ProjectNote?
    /// What caused it: `ui`, a session's id, or (later) an assistant job's.
    public var cause: String

    public init(id: UUID = UUID(), at: Date, actor: NoteAuthor, action: Action, before: ProjectNote? = nil,
                after: ProjectNote? = nil, cause: String) {
        self.id = id
        self.at = at
        self.actor = actor
        self.action = action
        self.before = before
        self.after = after
        self.cause = cause
    }
}

public protocol AssistantStoring: AnyObject {
    func load(projectID: UUID) throws -> AssistantData
    func save(_ data: AssistantData, projectID: UUID) throws
    func appendAudit(_ entry: AuditEntry, projectID: UUID) throws
    /// Where a project's data is kept, for error messages (nil in memory).
    func location(projectID: UUID) -> String?
}

extension AssistantStoring {
    public func location(projectID: UUID) -> String? { nil }
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
