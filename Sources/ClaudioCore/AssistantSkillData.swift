import Foundation

// Step 5 of the Project Assistant: what Claudio keeps about skills, per
// project, in `skills.json`. Kept apart from `assistant.json`, so adding to
// it doesn't make older builds read the notes and plan as read-only. Read
// tolerantly: entries that can't be read are kept as they were. A file that
// can't be read at all is left alone (nothing about skills is written that
// launch).

/// Which sessions used a skill, and when one last did. Approving a skill
/// counts as a use, so a skill nobody has needed yet isn't "unused" from the
/// day it's approved.
public struct SkillUsage: Codable, Equatable, Sendable {
    /// Sessions that used it, oldest first (at most `maxSessions`).
    public var sessions: [UUID] = []
    public var lastUsed: Date?

    public static let maxSessions = 200

    public init(sessions: [UUID] = [], lastUsed: Date? = nil) {
        self.sessions = sessions
        self.lastUsed = lastUsed
    }

    private enum CodingKeys: String, CodingKey { case sessions, lastUsed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = NeedsYouData.decodeEach(UUID.self, c, .sessions).read
        lastUsed = try? c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }
}

/// A skill draft waiting for you: New Skill, or Changed Skill (a patch to
/// an approved one). Nothing loads it until you approve it.
public struct SkillProposal: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// The lesson it came from.
    public var candidateID: UUID?
    public var name: String
    /// The whole proposed `SKILL.md`.
    public var text: String
    /// For a change: the approved text it was drafted against. Approve
    /// refuses if the file no longer matches it.
    public var previousText: String?
    /// "Why", for the card: the model's reason, under 20 words.
    public var why: String
    public var createdAt: Date
    /// The model that drafted it ("Sonnet").
    public var model: String
    /// What to check before approving (see `SkillCheck.warnings`), as of the
    /// draft or the last edit.
    public var warnings: [String] = []

    public init(candidateID: UUID?, name: String, text: String, previousText: String?, why: String, createdAt: Date, model: String,
                warnings: [String] = []) {
        self.candidateID = candidateID
        self.name = name
        self.text = text
        self.previousText = previousText
        self.why = why
        self.createdAt = createdAt
        self.model = model
        self.warnings = warnings
    }

    public var isChange: Bool { previousText != nil }

    private enum CodingKeys: String, CodingKey { case id, candidateID, name, text, previousText, why, createdAt, model, warnings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        candidateID = try c.decodeIfPresent(UUID.self, forKey: .candidateID)
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        previousText = try c.decodeIfPresent(String.self, forKey: .previousText)
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        warnings = (try? c.decodeIfPresent([String].self, forKey: .warnings)) ?? []
    }
}

/// Where an approved skill lives.
public enum SkillLocation: String, Codable, Sendable {
    /// Claudio's `--add-dir` root: every Claudio session in the project that
    /// uses the shared skills loads it (a session with its own set, only if chosen).
    case claudio
    /// `<repo>/.claude/skills`, after Save to Repository: yours to commit.
    case repository
    /// `retired/`, outside the root: no session loads it (step 5b).
    case retired
}

/// An approved skill Claudio manages: its version, where it lives, and the
/// hash of the text it approved (for the check for edits made outside Claudio).
public struct SkillRecord: Codable, Equatable, Sendable {
    /// `metadata.claudio-id`.
    public var id: UUID
    public var name: String
    public var version: Int
    public var approvedAt: Date
    /// `SkillText.hash` of the file as approved (or as Claudio last wrote it).
    public var contentHash: String
    public var location: SkillLocation = .claudio

    public init(id: UUID, name: String, version: Int, approvedAt: Date, contentHash: String, location: SkillLocation = .claudio) {
        self.id = id
        self.name = name
        self.version = version
        self.approvedAt = approvedAt
        self.contentHash = contentHash
        self.location = location
    }

    private enum CodingKeys: String, CodingKey { case id, name, version, approvedAt, contentHash, location }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Int.self, forKey: .version)
        approvedAt = try c.decode(Date.self, forKey: .approvedAt)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        location = try c.decodeIfPresent(SkillLocation.self, forKey: .location) ?? .claudio
    }
}

/// An approved skill's file changed, or went, without Claudio (step 5b):
/// a session edited it through `--add-dir`, or someone edited the
/// repository's copy. Needs You asks: Keep Change or Revert (Restore or
/// Keep Deletion for one that's gone).
public struct OutsideEdit: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var location: SkillLocation
    /// The file is gone.
    public var deleted: Bool
    /// `SkillText.hash` of the file as found (nil when it's gone).
    public var foundHash: String?
    public var foundAt: Date
    /// The session whose Edit or Write changed it, when the hooks showed one.
    public var editorSessionID: UUID?
    public var editorName: String?

    public init(name: String, location: SkillLocation, deleted: Bool, foundHash: String?, foundAt: Date,
                editorSessionID: UUID? = nil, editorName: String? = nil) {
        self.name = name
        self.location = location
        self.deleted = deleted
        self.foundHash = foundHash
        self.foundAt = foundAt
        self.editorSessionID = editorSessionID
        self.editorName = editorName
    }
}

/// An approved skill no session has used for `AppModel.unusedSkillDays`
/// (step 5b): Needs You asks Retire or Keep.
public struct UnusedSkill: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// Its last use (approving counts), as of the check.
    public var lastUsed: Date
    public var foundAt: Date

    public init(name: String, lastUsed: Date, foundAt: Date) {
        self.name = name
        self.lastUsed = lastUsed
        self.foundAt = foundAt
    }
}

/// What a project's `skills.json` holds.
public struct SkillsData: Codable, Equatable, Sendable {
    /// 1: usage, candidates, proposals and records. 2 (step 5b): a record's
    /// location, and what 5b adds. Bump it for any new field or candidate
    /// state: an older build then leaves a newer file alone (read-only)
    /// rather than drop what it doesn't know.
    public static let currentVersion = 2
    /// By skill name (what `/name` calls).
    public var usage: [String: SkillUsage] = [:]
    /// Usage entries that couldn't be read, kept as they were.
    public var unreadableUsage: [String: JSONValue] = [:]
    public var candidates: [LessonCandidate] = []
    public var proposals: [SkillProposal] = []
    public var records: [SkillRecord] = []
    /// Approved skills changed or removed outside Claudio, waiting for you.
    public var outsideEdits: [OutsideEdit] = []
    /// Approved skills unused for 30 days, waiting for you.
    public var unusedSkills: [UnusedSkill] = []
    /// Entries that couldn't be read, kept as they were.
    public var unreadableEntries: [String: [JSONValue]] = [:]

    public init(usage: [String: SkillUsage] = [:]) {
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey { case version, usage, candidates, proposals, records, outsideEdits, unusedSkills }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= SkillsData.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "Saved by a newer Claudio (version \(version))")
        }
        func each<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> [T] {
            let (read, unread) = NeedsYouData.decodeEach(type, c, key)
            if !unread.isEmpty { unreadableEntries[key.rawValue] = unread }
            return read
        }
        candidates = each(LessonCandidate.self, .candidates)
        proposals = each(SkillProposal.self, .proposals)
        records = each(SkillRecord.self, .records)
        outsideEdits = each(OutsideEdit.self, .outsideEdits)
        unusedSkills = each(UnusedSkill.self, .unusedSkills)
        let raw = ((try? c.decodeIfPresent([String: JSONValue].self, forKey: .usage)) ?? nil) ?? [:]
        let encoder = JSONEncoder()
        for (name, value) in raw {
            if let data = try? encoder.encode(value), let usage = try? JSONFileStore.decoder.decode(SkillUsage.self, from: data) {
                self.usage[name] = usage
            } else {
                unreadableUsage[name] = value
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(SkillsData.currentVersion, forKey: .version)
        var all: [String: JSONValue] = unreadableUsage
        let valueEncoder = JSONFileStore.encoder
        for (name, usage) in self.usage {
            all[name] = try JSONFileStore.decoder.decode(JSONValue.self, from: valueEncoder.encode(usage))
        }
        try c.encode(all, forKey: .usage)
        func each<T: Encodable>(_ values: [T], _ key: CodingKeys) throws {
            var array = c.nestedUnkeyedContainer(forKey: key)
            for value in values { try array.encode(value) }
            for raw in unreadableEntries[key.rawValue] ?? [] { try array.encode(raw) }
        }
        try each(candidates, .candidates)
        try each(proposals, .proposals)
        try each(records, .records)
        try each(outsideEdits, .outsideEdits)
        try each(unusedSkills, .unusedSkills)
    }

    public var isEmpty: Bool {
        usage.isEmpty && unreadableUsage.isEmpty && candidates.isEmpty && proposals.isEmpty && records.isEmpty
            && outsideEdits.isEmpty && unusedSkills.isEmpty && unreadableEntries.isEmpty
    }

    /// Candidates marked as having a draft waiting whose draft has gone
    /// (replaced by another lesson's draft for the same skill, or unreadable)
    /// go back to gathering, held for one more session, so none is stuck.
    public mutating func reconcileProposals() {
        let waiting = Set(proposals.compactMap(\.candidateID))
        for index in candidates.indices where candidates[index].state == .proposed && !waiting.contains(candidates[index].id) {
            candidates[index].holdBack(more: 1)
        }
    }

    /// Entries that couldn't be read, for the Activity Log.
    public var unreadableCount: Int { unreadableUsage.count + unreadableEntries.values.reduce(0) { $0 + $1.count } }

    /// Records a session using a skill at `date`. False when nothing worth
    /// saving changed: the session was already counted and the last use is
    /// the same day (hooks are polled twice a second, so not every use is
    /// written).
    public mutating func recordUse(of name: String, by sessionID: UUID, at date: Date, calendar: Calendar = .current) -> Bool {
        var entry = usage[name] ?? SkillUsage()
        let newSession = !entry.sessions.contains(sessionID)
        let newDay = entry.lastUsed.map { !calendar.isDate($0, inSameDayAs: date) || $0 > date } ?? true
        guard newSession || newDay else { return false }
        if newSession {
            entry.sessions.append(sessionID)
            if entry.sessions.count > SkillUsage.maxSessions { entry.sessions.removeFirst(entry.sessions.count - SkillUsage.maxSessions) }
        }
        if entry.lastUsed.map({ $0 < date }) ?? true { entry.lastUsed = date }
        usage[name] = entry
        return true
    }
}

/// Which skill a hook event shows a session using, if any. Claude invoking
/// one is a `PreToolUse` of the Skill tool (`tool_input.skill`); you typing
/// `/name` fires no tool event, only `UserPromptSubmit` with that prompt
/// (both recorded with 2.1.289 in `Fixtures/hook-skill-use.log`).
public enum SkillUseDetector {
    /// The skill's name; nil when the event isn't a skill use. A plugin's
    /// skill (`claudio:note`) isn't one of the project's.
    public static func skill(in event: HookEvent) -> String? {
        let name: String
        switch event.name {
        case .preToolUse where event.toolName == "Skill":
            guard let skill = event.toolInput?["skill"]?.stringValue else { return nil }
            name = skill
        case .userPromptSubmit:
            guard let prompt = event.prompt, prompt.hasPrefix("/") else { return nil }
            name = String(prompt.dropFirst().prefix { !$0.isWhitespace })
        default:
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.contains("/") else { return nil }
        return trimmed
    }
}
