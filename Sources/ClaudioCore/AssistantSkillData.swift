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

/// What a project's `skills.json` holds.
public struct SkillsData: Codable, Equatable, Sendable {
    /// By skill name (what `/name` calls).
    public var usage: [String: SkillUsage] = [:]
    /// Usage entries that couldn't be read, kept as they were.
    public var unreadableUsage: [String: JSONValue] = [:]

    public init(usage: [String: SkillUsage] = [:]) {
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey { case usage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
        var all: [String: JSONValue] = unreadableUsage
        let valueEncoder = JSONFileStore.encoder
        for (name, usage) in self.usage {
            all[name] = try JSONFileStore.decoder.decode(JSONValue.self, from: valueEncoder.encode(usage))
        }
        try c.encode(all, forKey: .usage)
    }

    public var isEmpty: Bool { usage.isEmpty && unreadableUsage.isEmpty }

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
