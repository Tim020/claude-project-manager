import Foundation

// The Project Assistant's data (design 9a, `design/Project Assistant
// Backend.md`): per project, kept apart from `state.json` because it grows
// without limit. Notes are saved straight away, whoever writes them; notes
// the assistant or a session wrote can be undone.

/// Who wrote a note.
public enum NoteAuthor: String, Codable, CaseIterable, Sendable {
    /// You, from the capture box (⌘⇧N).
    case user
    /// The assistant, from a session's follow-ups.
    case assistant
    /// A Claude Code session, with `claudio note` while it worked.
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
        // An author from a newer version reads as the assistant's, so it keeps its Undo.
        author = (try? c.decodeIfPresent(NoteAuthor.self, forKey: .author)) ?? .assistant
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
        notes = try c.decodeIfPresent([ProjectNote].self, forKey: .notes) ?? []
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
/// id, not path, so moving a project's folder keeps its notes.
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
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
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
