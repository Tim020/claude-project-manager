import Foundation

// Step 4 of the Project Assistant: follow-ups. When a session looks done
// it's offered one; on Follow Up (or Review This Session), one Claude call
// (Sonnet unless the project's Assistant Settings choose another)
// reads a digest of what it did and suggests notes (saved straight away,
// undoable) and plan changes (applied only when you choose Add to Plan).
// Needs You lists what's waiting for you: offers, finished and failed
// follow-ups, and plan changes sessions suggested with `claudio suggest`.

/// A plan change a follow-up suggests. Nothing changes until you add it.
public struct ProposedPlanChange: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A new item.
        case add
        /// Mark an existing item Done.
        case done
        /// Move an existing item to another status.
        case move
    }

    public var id = UUID()
    public var kind: Kind
    /// The item it changes (done, move).
    public var itemID: UUID?
    /// The new item's title, or the changed item's title when suggested.
    public var title: String
    /// The new status (add, move).
    public var status: PlanStatus
    public var reason: String
    /// Ticked on the card: Add n to Plan applies the ticked ones.
    public var isSelected = true

    public init(kind: Kind, itemID: UUID? = nil, title: String, status: PlanStatus, reason: String) {
        self.kind = kind
        self.itemID = itemID
        self.title = title
        self.status = status
        self.reason = reason
    }

    /// A new item: Planned or an Idea.
    public static func add(title: String, status: PlanStatus, reason: String) -> ProposedPlanChange {
        ProposedPlanChange(kind: .add, title: title, status: status == .idea ? .idea : .planned, reason: reason)
    }

    /// An existing item to another status: Done is `.done`, others `.move`.
    public static func setStatus(of item: PlanItem, to status: PlanStatus, reason: String) -> ProposedPlanChange {
        ProposedPlanChange(kind: status == .done ? .done : .move, itemID: item.id, title: item.title, status: status,
                           reason: reason)
    }

    /// Whether it makes sense: a new item is Planned or an Idea and has no
    /// item; a status change has an item, "done" is Done, and nothing moves
    /// an item to In Session (that comes from starting a session). Checked
    /// again when it's applied, since it may come from a file.
    public var isValid: Bool {
        switch kind {
        case .add: return itemID == nil && (status == .planned || status == .idea) && !title.isEmpty
        case .done: return itemID != nil && status == .done
        case .move: return itemID != nil && status != .done && status != .inSession
        }
    }

    private enum CodingKeys: String, CodingKey { case id, kind, itemID, title, status, reason, isSelected }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        itemID = try c.decodeIfPresent(UUID.self, forKey: .itemID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decode(PlanStatus.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "A plan change that doesn't make sense")
        }
    }

    /// "New Planned item", "Mark Done", "Move to Idea".
    public var label: String {
        switch kind {
        case .add: return status == .idea ? "New Idea" : "New \(status.label) item"
        case .done: return "Mark Done"
        case .move: return "Move to \(status.label)"
        }
    }
}

/// One session's follow-up, from the moment it's asked for until you close it.
public struct FollowUp: Codable, Equatable, Identifiable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        /// The session looks ready: "<session> looks done. Follow up?". No
        /// call until you accept (not saved: it's offered again if it still applies).
        case offered
        /// The call is running or waiting for its turn (not saved).
        case working
        case ready
        /// The call failed, in the panel's words. Try Again asks again.
        case failed(String)
    }

    public var id = UUID()
    public var sessionID: UUID
    /// The session's name when it was asked for, for when it's gone.
    public var sessionName: String
    public var state: State
    /// Notes it saved. They're already in Notes: unticking one removes it
    /// (its `noteID` becomes nil), and ticking it again saves it again.
    public var notes: [FollowUpNote] = []
    public var planChanges: [ProposedPlanChange] = []
    public var createdAt: Date
    /// It ran because you asked: Follow Up on an offer, or Review This
    /// Session. False only for an offer.
    public var askedFor: Bool
    /// The model it ran on ("Sonnet"), for Job Failed.
    public var model: String?
    /// Later, or ✕: the card leaves the session and waits in Needs You.
    public var isDeferred = false

    public init(sessionID: UUID, sessionName: String, state: State, createdAt: Date, askedFor: Bool) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.state = state
        self.createdAt = createdAt
        self.askedFor = askedFor
    }

    public var hasNothingToKeep: Bool { state == .ready && notes.isEmpty && planChanges.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, sessionName, state, notes, planChanges, createdAt, askedFor, isDeferred, model
    }

    /// Tolerant: fields a later build adds, or leaves out, take defaults. A
    /// state it doesn't know fails this entry only (see `NeedsYouData`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? "A session"
        state = try c.decode(State.self, forKey: .state)
        notes = NeedsYouData.decodeEach(FollowUpNote.self, c, .notes).read
        planChanges = NeedsYouData.decodeEach(ProposedPlanChange.self, c, .planChanges).read
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        askedFor = try c.decodeIfPresent(Bool.self, forKey: .askedFor) ?? true
        isDeferred = try c.decodeIfPresent(Bool.self, forKey: .isDeferred) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// A note a follow-up wrote: its text, and the note in Notes while it's kept.
public struct FollowUpNote: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String
    public var noteID: UUID?

    public init(text: String, noteID: UUID?) {
        self.text = text
        self.noteID = noteID
    }

    public var isKept: Bool { noteID != nil }

    private enum CodingKeys: String, CodingKey { case id, text, noteID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        noteID = try c.decodeIfPresent(UUID.self, forKey: .noteID)
    }
}

/// A plan change a session suggested with `claudio suggest`.
public struct SessionSuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var sessionID: UUID?
    public var sessionName: String?
    public var text: String
    public var createdAt: Date

    public init(sessionID: UUID?, sessionName: String?, text: String, createdAt: Date) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.text = text
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, sessionID, sessionName, text, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// What's in a project's Needs You, saved as `needs-you.json`. Throwaway,
/// like `suggestions.json`: no audit, no version. Entries that can't be read
/// are kept as they were. Offers, and follow-ups still working when Claudio
/// quits, aren't kept: their session's mark wasn't moved, so it may be
/// offered again.
public struct NeedsYouData: Codable, Equatable, Sendable {
    public var followUps: [FollowUp] = []
    public var suggestions: [SessionSuggestion] = []
    /// Entries that couldn't be read (from a later build, or cut short),
    /// kept as they were and written back, so one doesn't cost the rest.
    public var unreadableFollowUps: [JSONValue] = []
    public var unreadableSuggestions: [JSONValue] = []

    public init(followUps: [FollowUp] = [], suggestions: [SessionSuggestion] = []) {
        self.followUps = followUps
        self.suggestions = suggestions
    }

    private enum CodingKeys: String, CodingKey { case followUps, suggestions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (followUps, unreadableFollowUps) = NeedsYouData.decodeEach(FollowUp.self, c, .followUps)
        (suggestions, unreadableSuggestions) = NeedsYouData.decodeEach(SessionSuggestion.self, c, .suggestions)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var followUpsArray = c.nestedUnkeyedContainer(forKey: .followUps)
        for followUp in followUps { try followUpsArray.encode(followUp) }
        for raw in unreadableFollowUps { try followUpsArray.encode(raw) }
        var suggestionsArray = c.nestedUnkeyedContainer(forKey: .suggestions)
        for suggestion in suggestions { try suggestionsArray.encode(suggestion) }
        for raw in unreadableSuggestions { try suggestionsArray.encode(raw) }
    }

    /// An array read one entry at a time: those that read, and the rest as they were.
    static func decodeEach<T: Decodable, K: CodingKey>(_ type: T.Type, _ c: KeyedDecodingContainer<K>, _ key: K)
        -> (read: [T], unread: [JSONValue]) {
        guard let raw = ((try? c.decodeIfPresent([JSONValue].self, forKey: key)) ?? nil) else { return ([], []) }
        var read: [T] = []
        var unread: [JSONValue] = []
        let encoder = JSONEncoder()
        for entry in raw {
            if let data = try? encoder.encode(entry), let value = try? JSONFileStore.decoder.decode(T.self, from: data) {
                read.append(value)
            } else {
                unread.append(entry)
            }
        }
        return (read, unread)
    }

    /// What's saved: everything but offers and follow-ups still working.
    public var saved: NeedsYouData {
        var data = NeedsYouData(followUps: followUps.filter { $0.state != .working && $0.state != .offered },
                                suggestions: suggestions)
        data.unreadableFollowUps = unreadableFollowUps
        data.unreadableSuggestions = unreadableSuggestions
        return data
    }

    public var unreadableCount: Int { unreadableFollowUps.count + unreadableSuggestions.count }

    public var isEmpty: Bool { followUps.isEmpty && suggestions.isEmpty && unreadableCount == 0 }
}

/// Counts background calls per day, for the daily limit (users without a
/// plan-usage reading have no other cap).
public struct DailyJobCount: Codable, Equatable, Sendable {
    /// "2026-09-29", in the user's time zone.
    public var day: String
    public var count: Int

    public init(day: String, count: Int) {
        self.day = day
        self.count = count
    }

    public static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}


// MARK: - The follow-up call

public enum FollowUpJob {
    public static let job = "Follow-up"
    /// A follow-up measured about $0.01 and 2 s on Sonnet (2.1.285, short
    /// digests). The cap stops one that runs away: $0.10 on Haiku, scaled by
    /// model ($0.30 on Sonnet, an estimated $1.50 on Opus).
    public static let budgetUSD = 0.10
    public static let timeout = 120
    /// The whole input, in characters. It goes on the command line, so it's
    /// capped well below any limit; the digest's own caps keep it far under.
    public static let maxInput = 60_000
    /// Notes and plan changes kept from one reply, at most.
    public static let maxNotes = 5
    public static let maxPlanChanges = 5

    static let systemPrompt = """
    You follow up on one finished Claude Code session for the user, who keeps a notebook and a plan for the project.
    You get a digest of what the session did since the last follow-up, the project's plan (items by ref), the plan item the session works on (if any), the notes the session already has, and the project's memory index.
    notes: things worth keeping that aren't in the code, the git history or the memory index: a decision and why, a gotcha found the hard way, a follow-up that's out of scope. One or two plain sentences each, understandable without the session. Don't repeat existing notes or summarise what the session did. Usually zero to two; never more than five.
    planChanges: only clear ones. "add" for new work the session found (title under 60 characters, status "planned" or "idea"). "done" when the digest shows an item's work finished (committed, or a PR opened or merged). "move" to change an item's status. Use the item's ref for done and move. Usually none.
    lessons: something future sessions in this project should know, learned the hard way: a command that failed and what worked instead, or a way of working the user corrected. Not facts about the code. summary: one or two plain sentences, written as advice to a future session. evidence: the refs of the digest's failures (f1…) and corrections (c1…) it rests on; never invent one, and leave the lesson out if none fits. remember: true only when the user explicitly asked Claude to remember it, or to do it differently next time. Usually none; never more than three.
    reason: under 12 words, for the user.
    British English. When nothing is worth keeping, return empty lists. Reply only through the schema.
    """

    static let schema = #"{"type":"object","properties":{"notes":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}},"planChanges":{"type":"array","items":{"type":"object","properties":{"kind":{"type":"string","enum":["add","done","move"]},"ref":{"type":["string","null"]},"title":{"type":"string"},"status":{"type":"string","enum":["planned","idea","inSession","done"]},"reason":{"type":"string"}},"required":["kind","ref","title","status","reason"],"additionalProperties":false}},"lessons":{"type":"array","items":{"type":"object","properties":{"summary":{"type":"string"},"evidence":{"type":"array","items":{"type":"string"}},"remember":{"type":"boolean"}},"required":["summary","evidence","remember"],"additionalProperties":false}}},"required":["notes","planChanges","lessons"],"additionalProperties":false}"#

    public struct Request: Equatable, Sendable {
        public var call: AssistantCall
        /// What each ref in the call stands for.
        public var refs: [String: UUID]
        /// The history lines the digest read: the session's new mark.
        public var mark: FollowUpMark
        /// The digest's failures and corrections by ref, for its lessons
        /// (empty when transcripts aren't sent: then there are none).
        public var evidence: [String: SessionDigest.Evidence] = [:]
    }

    public static func request(digest: SessionDigest, mark: FollowUpMark, sessionName: String, items: [PlanItem],
                               sessionItem: PlanItem?, sessionNotes: [ProjectNote], memoryIndex: String?,
                               withTranscripts: Bool = true, model: AssistantModel = .sonnet) -> Request {
        let offered = PromoteCheck.refs(for: items)
        let refByItem = Dictionary(uniqueKeysWithValues: offered.map { ($0.item.id, $0.ref) })
        let plan: [JSONValue] = offered.map {
            .object(["ref": .string($0.ref), "title": .string($0.item.title), "status": .string($0.item.status.rawValue)])
        }
        var input: [String: JSONValue] = [
            "session": .string(sessionName),
            "digest": digest.json(withTranscripts: withTranscripts),
            "plan": .array(plan),
            "sessionNotes": .array(sessionNotes.suffix(20).map { .string(ToolSummary.truncate($0.text, to: 500)) }),
        ]
        if let item = sessionItem, let ref = refByItem[item.id] { input["sessionItem"] = .string(ref) }
        if let memoryIndex, !memoryIndex.isEmpty { input["memoryIndex"] = .string(String(memoryIndex.prefix(4000))) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var text = (try? encoder.encode(JSONValue.object(input))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if text.count > maxInput {
            // Only reached with a very long plan: drop the memory index, then the plan.
            input["memoryIndex"] = nil
            text = (try? encoder.encode(JSONValue.object(input))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            if text.count > maxInput {
                input["plan"] = .array(Array(plan.prefix(50)))
                text = (try? encoder.encode(JSONValue.object(input))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            }
        }
        let call = AssistantCall(job: job, model: model.rawValue, systemPrompt: systemPrompt, schema: schema, input: text,
                                 maxBudgetUSD: budgetUSD * model.budgetFactor, timeout: timeout)
        return Request(call: call, refs: Dictionary(uniqueKeysWithValues: offered.map { ($0.ref, $0.item.id) }),
                       mark: mark,
                       evidence: withTranscripts ? Dictionary(digest.evidence.map { ($0.ref, $0) }) { first, _ in first } : [:])
    }

    /// Notes and plan changes from a reply. It's untrusted: refs are looked
    /// up in the call's own map and must still be in the plan and not done;
    /// titles are cleaned; anything that doesn't make sense is dropped.
    public static func result(from reply: JSONValue, refs: [String: UUID], items: [PlanItem])
        -> (notes: [String], planChanges: [ProposedPlanChange]) {
        let notes = (reply["notes"]?.arrayValue ?? [])
            .compactMap { $0["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxNotes)
            .map { String($0.prefix(AppModel.sessionNoteLimit)) }
        var changes: [ProposedPlanChange] = []
        for raw in reply["planChanges"]?.arrayValue ?? [] {
            guard changes.count < maxPlanChanges,
                  let kind = raw["kind"]?.stringValue.flatMap(ProposedPlanChange.Kind.init(rawValue:)) else { continue }
            let reason = SuggestionCopy.sentence(raw["reason"]?.stringValue ?? "")
            let status = raw["status"]?.stringValue.flatMap(PlanStatus.init(rawValue:))
            switch kind {
            case .add:
                let title = PlanTitle.clean(raw["title"]?.stringValue ?? "")
                guard !title.isEmpty else { continue }
                changes.append(.add(title: title, status: status ?? .planned, reason: reason))
            case .done, .move:
                guard let ref = raw["ref"]?.stringValue, let itemID = refs[ref],
                      let item = items.first(where: { $0.id == itemID && $0.status != .done }) else { continue }
                let target: PlanStatus = kind == .done ? .done : (status ?? item.status)
                // In Session comes from starting a session, not a suggestion.
                guard target != item.status, target != .inSession else { continue }
                changes.append(.setStatus(of: item, to: target, reason: reason))
            }
        }
        return (Array(notes), changes)
    }
}
