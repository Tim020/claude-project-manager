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
    /// A Claude Code session, with `claudio note` from Claudio's plugin.
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
    /// A session is working on it (from Start Session).
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
    // No folder: an item isn't filed. The folder is chosen for the session
    // started from it (New Session from Plan). Step 2 files have a
    // `folderID`, which is ignored and dropped on the next save.
    /// Its GitHub issue, "#23" (build step 6).
    public var issue: String?
    /// The session working on it (from Start Session).
    public var sessionID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, status: PlanStatus, issue: String? = nil,
                sessionID: UUID? = nil, createdAt: Date) {
        self.id = id
        self.title = title
        self.status = status
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
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// How much the assistant does in a project (design 9a, Assistant Settings;
/// its UI comes in build step 4).
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
    /// 2: plan items, the project's mode, and per-entry decoding. Bump it for
    /// any new field on a note, an item or `AssistantData`: older builds
    /// refuse a newer file rather than drop what they don't know about.
    public static let currentVersion = 2
    public var version = AssistantData.currentVersion
    /// Oldest first, as written.
    public var notes: [ProjectNote] = []
    /// Oldest first, as created.
    public var items: [PlanItem] = []
    public var mode = AssistantMode.automatic
    /// Entries kept as they were. They're written back after the readable
    /// ones, so one that becomes readable again sorts as the newest. Their
    /// numbers pass through `JSONValue` as doubles (ids and dates are
    /// strings, so nothing Claudio writes is affected).
    public var unreadableNotes: [JSONValue] = []
    public var unreadableItems: [JSONValue] = []
    /// Why each kept entry couldn't be read, for the Activity Log (not saved).
    public var unreadableReasons: [String] = []

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
        let noteReasons: [String], itemReasons: [String]
        (notes, unreadableNotes, noteReasons) = try AssistantData.decodeEach(ProjectNote.self, c, .notes, "A note")
        (items, unreadableItems, itemReasons) = try AssistantData.decodeEach(PlanItem.self, c, .items, "A plan item")
        unreadableReasons = noteReasons + itemReasons
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

    /// Decodes an array one entry at a time: the entries that read, the
    /// ones that don't (as they were), and why each didn't.
    private static func decodeEach<T: Decodable>(_ type: T.Type, _ c: KeyedDecodingContainer<CodingKeys>,
                                                 _ key: CodingKeys, _ noun: String) throws -> ([T], [JSONValue], [String]) {
        guard let raw = try c.decodeIfPresent([JSONValue].self, forKey: key) else { return ([], [], []) }
        var read: [T] = []
        var unread: [JSONValue] = []
        var reasons: [String] = []
        let encoder = JSONEncoder()
        let decoder = JSONFileStore.decoder
        for (index, entry) in raw.enumerated() {
            do {
                read.append(try decoder.decode(T.self, from: encoder.encode(entry)))
            } catch {
                unread.append(entry)
                reasons.append("\(noun) (entry \(index + 1)): \(AssistantData.describe(error))")
            }
        }
        return (read, unread, reasons)
    }

    /// "status: an unknown value", from a DecodingError.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).filter { Int($0) == nil }.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, _): return "\(key.stringValue) is missing"
        case .valueNotFound(_, let context): return "\(path(context)) is empty"
        case .typeMismatch(_, let context), .dataCorrupted(let context):
            let field = path(context)
            return field.isEmpty ? context.debugDescription : "\(field): \(context.debugDescription)"
        @unknown default: return String(describing: error)
        }
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

    /// One assistant call, for the Assistant's Activity Log (build step 4).
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
    /// The suggestions showing on a project's notes, so a relaunch shows
    /// them again. Kept apart from `assistant.json`: they're throwaway (no
    /// audit, no version), so a file that can't be read is just empty.
    func loadSuggestions(projectID: UUID) -> [UUID: NoteSuggestion]
    func saveSuggestions(_ suggestions: [UUID: NoteSuggestion], projectID: UUID) throws
    // What sessions get (build step 3). A store that keeps nothing on disk
    // gives sessions no flags.
    /// Writes Claudio's plugin out if it isn't there as it should be, and
    /// returns where it is (nil: sessions don't get it).
    func installPlugin() throws -> URL?
    /// The plugin already on disk, if it has its command (used when an
    /// update fails: the old copy still works).
    func existingPlugin() -> URL?
    /// A project's skills root, created with its `.claude/skills` folder
    /// (which must exist before a session starts for skills to load live).
    func skillsRoot(projectID: UUID) throws -> URL?
    func approvedSkills(projectID: UUID) -> [ApprovedSkill]
    /// `index.tsv`, for `bin/claudio`. Only written when it changes.
    func writeIndex(_ text: String) throws
    /// A project's `plan.md`, for `claudio plan`. Only written when it changes.
    func writePlanSnapshot(_ text: String, projectID: UUID) throws
    /// The inbox lines sessions wrote since the last call (see `InboxReader`).
    /// Throws, taking nothing, when where it got to can't be saved.
    func takeInbox() throws -> [String]
    // Step 4: Needs You (throwaway, like suggestions) and the daily limit.
    func loadNeedsYou(projectID: UUID) -> NeedsYouData
    func saveNeedsYou(_ data: NeedsYouData, projectID: UUID) throws
    func loadDailyJobs() -> DailyJobCount?
    func saveDailyJobs(_ count: DailyJobCount) throws
    /// Whether a count file exists (to tell "none yet" from "unreadable").
    func hasDailyJobsFile() -> Bool
    // Step 4b: Assistant Settings (tolerant, no version) and the audit log's reader.
    func loadProjectSettings(projectID: UUID) -> ProjectAssistantSettings
    func saveProjectSettings(_ settings: ProjectAssistantSettings, projectID: UUID) throws
    /// The newest lines of `audit.jsonl` that read, oldest first, and how
    /// many didn't (from a later build, or a line cut short).
    func readAudit(projectID: UUID, limit: Int) -> (entries: [AuditEntry], unreadable: Int)
}

extension AssistantStoring {
    public func location(projectID: UUID) -> String? { nil }
    public func runsDirectory() -> URL? { nil }
    public func loadSuggestions(projectID: UUID) -> [UUID: NoteSuggestion] { [:] }
    public func saveSuggestions(_ suggestions: [UUID: NoteSuggestion], projectID: UUID) throws {}
    public func installPlugin() throws -> URL? { nil }
    public func existingPlugin() -> URL? { nil }
    public func skillsRoot(projectID: UUID) throws -> URL? { nil }
    public func approvedSkills(projectID: UUID) -> [ApprovedSkill] { [] }
    public func writeIndex(_ text: String) throws {}
    public func writePlanSnapshot(_ text: String, projectID: UUID) throws {}
    public func takeInbox() throws -> [String] { [] }
    public func loadNeedsYou(projectID: UUID) -> NeedsYouData { NeedsYouData() }
    public func saveNeedsYou(_ data: NeedsYouData, projectID: UUID) throws {}
    public func loadDailyJobs() -> DailyJobCount? { nil }
    public func saveDailyJobs(_ count: DailyJobCount) throws {}
    public func hasDailyJobsFile() -> Bool { false }
    public func loadProjectSettings(projectID: UUID) -> ProjectAssistantSettings { ProjectAssistantSettings() }
    public func saveProjectSettings(_ settings: ProjectAssistantSettings, projectID: UUID) throws {}
    public func readAudit(projectID: UUID, limit: Int) -> (entries: [AuditEntry], unreadable: Int) { ([], 0) }
}

/// Keeps assistant data in memory: the default, so tests and previews never
/// touch the real files.
public final class MemoryAssistantStore: AssistantStoring {
    public var data: [UUID: AssistantData] = [:]
    public var audit: [UUID: [AuditEntry]] = [:]
    public var suggestions: [UUID: [UUID: NoteSuggestion]] = [:]
    public var skills: [UUID: [ApprovedSkill]] = [:]
    public var index: String?
    public var planSnapshots: [UUID: String] = [:]
    /// Lines waiting for `takeInbox`.
    public var inbox: [String] = []
    /// Makes `takeInbox` throw, as a file store does when it can't save its place.
    public var inboxError: Error?
    public var needsYou: [UUID: NeedsYouData] = [:]
    public var dailyJobs: DailyJobCount?
    /// Makes `save` throw, as a full disk would (for tests).
    public var saveError: Error?

    public init() {}

    public func load(projectID: UUID) throws -> AssistantData { data[projectID] ?? AssistantData() }
    public func save(_ data: AssistantData, projectID: UUID) throws {
        if let saveError { throw saveError }
        self.data[projectID] = data
    }
    public func appendAudit(_ entry: AuditEntry, projectID: UUID) throws { audit[projectID, default: []].append(entry) }
    public func loadSuggestions(projectID: UUID) -> [UUID: NoteSuggestion] { suggestions[projectID] ?? [:] }
    public func saveSuggestions(_ suggestions: [UUID: NoteSuggestion], projectID: UUID) throws {
        self.suggestions[projectID] = suggestions
    }
    public func approvedSkills(projectID: UUID) -> [ApprovedSkill] { skills[projectID] ?? [] }
    public func writeIndex(_ text: String) throws { index = text }
    public func writePlanSnapshot(_ text: String, projectID: UUID) throws { planSnapshots[projectID] = text }
    public func takeInbox() throws -> [String] {
        if let inboxError { throw inboxError }
        defer { inbox = [] }
        return inbox
    }
    public func loadNeedsYou(projectID: UUID) -> NeedsYouData { needsYou[projectID] ?? NeedsYouData() }
    public func saveNeedsYou(_ data: NeedsYouData, projectID: UUID) throws { needsYou[projectID] = data }
    public func loadDailyJobs() -> DailyJobCount? { dailyJobs }
    public func saveDailyJobs(_ count: DailyJobCount) throws { dailyJobs = count }
    public func hasDailyJobsFile() -> Bool { dailyJobs != nil }
    public var projectSettings: [UUID: ProjectAssistantSettings] = [:]
    public func loadProjectSettings(projectID: UUID) -> ProjectAssistantSettings {
        projectSettings[projectID] ?? ProjectAssistantSettings()
    }
    public func saveProjectSettings(_ settings: ProjectAssistantSettings, projectID: UUID) throws {
        projectSettings[projectID] = settings
    }
    public func readAudit(projectID: UUID, limit: Int) -> (entries: [AuditEntry], unreadable: Int) {
        (Array((audit[projectID] ?? []).suffix(limit)), 0)
    }
}

/// `<root>/<project id>/assistant.json` and `audit.jsonl`, by default under
/// `~/Library/Application Support/Claudio/assistant`. Projects are keyed by
/// id, not path: the notes belong to the project entry, so removing and
/// re-adding a project starts it afresh.
public final class AssistantFileStore: AssistantStoring {
    public let root: URL
    /// Kept, so the place it got to is remembered even if saving it fails.
    private let inboxReader: InboxReader

    public init(root: URL) {
        self.root = root
        inboxReader = InboxReader(url: root.appendingPathComponent("inbox.log"))
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

    /// `suggestions.json`: note id → suggestion. Entries that can't be read
    /// are skipped; the next save writes what's showing.
    public func loadSuggestions(projectID: UUID) -> [UUID: NoteSuggestion] {
        let url = directory(projectID: projectID).appendingPathComponent("suggestions.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return [:] }
        var suggestions: [UUID: NoteSuggestion] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key), let encoded = try? JSONEncoder().encode(value),
                  let suggestion = try? JSONDecoder().decode(NoteSuggestion.self, from: encoded)
            else { continue }
            suggestions[id] = suggestion
        }
        return suggestions
    }

    public func saveSuggestions(_ suggestions: [UUID: NoteSuggestion], projectID: UUID) throws {
        let directory = directory(projectID: projectID)
        let url = directory.appendingPathComponent("suggestions.json")
        if suggestions.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyed = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.key.uuidString.lowercased(), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(keyed).write(to: url, options: .atomic)
    }

    /// `plugin/claudio`, beside the assistant's folder.
    public var pluginDirectory: URL {
        root.deletingLastPathComponent().appendingPathComponent("plugin").appendingPathComponent("claudio")
    }

    public func installPlugin() throws -> URL? {
        try ClaudioPlugin.install(at: pluginDirectory)
        return pluginDirectory
    }

    public func existingPlugin() -> URL? {
        FileManager.default.isExecutableFile(atPath: pluginDirectory.appendingPathComponent("bin/claudio").path)
            ? pluginDirectory : nil
    }

    public func skillsRoot(projectID: UUID) throws -> URL? {
        let skills = directory(projectID: projectID).appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills.appendingPathComponent(".claude/skills"),
                                                withIntermediateDirectories: true)
        return skills
    }

    public func approvedSkills(projectID: UUID) -> [ApprovedSkill] {
        SkillFiles.approved(inRoot: directory(projectID: projectID).appendingPathComponent("skills"))
    }

    public func writeIndex(_ text: String) throws {
        try writeIfChanged(text, to: root.appendingPathComponent("index.tsv"))
    }

    public func writePlanSnapshot(_ text: String, projectID: UUID) throws {
        try writeIfChanged(text, to: directory(projectID: projectID).appendingPathComponent("plan.md"))
    }

    public func takeInbox() throws -> [String] {
        try inboxReader.take()
    }

    /// `needs-you.json`; one that can't be read is empty.
    public func loadNeedsYou(projectID: UUID) -> NeedsYouData {
        let url = directory(projectID: projectID).appendingPathComponent("needs-you.json")
        guard let data = try? Data(contentsOf: url) else { return NeedsYouData() }
        return (try? JSONFileStore.decoder.decode(NeedsYouData.self, from: data)) ?? NeedsYouData()
    }

    public func saveNeedsYou(_ data: NeedsYouData, projectID: UUID) throws {
        let url = directory(projectID: projectID).appendingPathComponent("needs-you.json")
        if data.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONFileStore.encoder.encode(data).write(to: url, options: .atomic)
    }

    /// `daily-jobs.json`, beside the projects' folders.
    public func loadDailyJobs() -> DailyJobCount? {
        (try? Data(contentsOf: root.appendingPathComponent("daily-jobs.json")))
            .flatMap { try? JSONDecoder().decode(DailyJobCount.self, from: $0) }
    }

    public func hasDailyJobsFile() -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("daily-jobs.json").path)
    }

    /// `settings.json`; one that can't be read gives the defaults.
    public func loadProjectSettings(projectID: UUID) -> ProjectAssistantSettings {
        let url = directory(projectID: projectID).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url) else { return ProjectAssistantSettings() }
        return (try? JSONDecoder().decode(ProjectAssistantSettings.self, from: data)) ?? ProjectAssistantSettings()
    }

    public func saveProjectSettings(_ settings: ProjectAssistantSettings, projectID: UUID) throws {
        let directory = directory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
    }

    /// Reads from the end, at most `limit` lines (and at most 4 MB), so a
    /// long log stays quick. Lines that don't decode are skipped and counted:
    /// the first, when the read starts part-way through a line, isn't counted.
    public func readAudit(projectID: UUID, limit: Int) -> (entries: [AuditEntry], unreadable: Int) {
        let url = directory(projectID: projectID).appendingPathComponent("audit.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }
        let maxBytes: UInt64 = 4 * 1024 * 1024
        guard let size = try? handle.seekToEnd() else { return ([], 0) }
        let start = size > maxBytes ? size - maxBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return ([], 0) }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var entries: [AuditEntry] = []
        var unreadable = 0
        for line in lines.suffix(limit) {
            if let entry = try? JSONFileStore.decoder.decode(AuditEntry.self, from: Data(line.utf8)) {
                entries.append(entry)
            } else {
                unreadable += 1
            }
        }
        return (entries, unreadable)
    }

    public func saveDailyJobs(_ count: DailyJobCount) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(count).write(to: root.appendingPathComponent("daily-jobs.json"), options: .atomic)
    }

    private func writeIfChanged(_ text: String, to url: URL) throws {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
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
    /// You removed the link (the × in the capture box), so New Note pressed
    /// again doesn't put it back.
    public var isLinkRemoved = false

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
