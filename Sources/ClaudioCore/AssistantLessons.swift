import Foundation

// Step 5 of the Project Assistant: lessons. A follow-up may find a lesson
// (something future sessions should know, learned the hard way), which
// must cite the digest's failures or corrections. Code gives each a
// signature from that evidence, never from the model's words, and keeps it
// as a candidate. A skill is only drafted once the same signature has come
// up in two sessions, or you told Claude to remember it.

/// A lesson a follow-up found, with the evidence it cites (resolved in code).
public struct LessonFinding: Equatable, Sendable {
    public var summary: String
    public var evidence: [SessionDigest.Evidence]
    /// You told Claude to remember it: set only when a cited correction
    /// says so in your own words, whatever the model claims.
    public var remember: Bool
    /// From the evidence: see `LessonSignature`.
    public var signature: String
}

public enum LessonSignature {
    /// A lesson's signature, from the first failure it cites that has one,
    /// else its first correction that has one:
    /// - a failed Bash command: its first two words and the error's first
    ///   line, normalised ("bash swift test | error: # tests failed");
    /// - another tool: the tool and the file ("edit Sources/a.swift");
    /// - a correction: its first six words that aren't filler ("no",
    ///   "don't", "the"…), wherever they are.
    /// Nil when none has anything to go on (a command of only `cd`, a
    /// correction of only filler words, a failure with no file), so
    /// unrelated lessons don't share one empty signature.
    public static func of(_ evidence: [SessionDigest.Evidence]) -> String? {
        evidence.filter { $0.kind == .failure }.lazy.compactMap(of).first
            ?? evidence.filter { $0.kind == .correction }.lazy.compactMap(of).first
    }

    public static func of(_ evidence: SessionDigest.Evidence) -> String? {
        switch evidence.kind {
        case .failure:
            if let command = evidence.command, !command.isEmpty {
                let head = commandHead(command)
                return head.isEmpty ? nil : "bash \(head) | \(errorHead(evidence.text))"
            }
            guard let file = evidence.file, !file.isEmpty else { return nil }
            return "\((evidence.tool ?? "tool").lowercased()) \(file)"
        case .correction:
            let words = correctionWords(evidence.text)
            return words.isEmpty ? nil : "correction " + words
        }
    }

    /// The command that ran, without `cd …&&`, variables set before it or
    /// `sudo`: its name (a path's last part) and its first argument when
    /// that isn't an option or a path ("swift test", "test-linux.sh").
    static func commandHead(_ command: String) -> String {
        let segments = command.replacingOccurrences(of: ";", with: "&&").components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("cd ") && !$0.hasPrefix("export ") }
        guard let segment = segments.first else { return "" }
        var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, first == "sudo" || first == "env" || (first.contains("=") && !first.hasPrefix("-")) {
            words.removeFirst()
        }
        guard let name = words.first.map({ ($0 as NSString).lastPathComponent }) else { return "" }
        if words.count > 1, !words[1].hasPrefix("-"), !words[1].contains("/"), !words[1].contains("\""), !words[1].contains("'") {
            return "\(name) \(words[1])"
        }
        return name
    }

    /// The error's first line that says something (not "Exit code 1"), in
    /// lower case, with paths, numbers and ids taken out, at most 80 characters.
    static func errorHead(_ text: String) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.lowercased().hasPrefix("exit code") } ?? ""
        var normalised = line.lowercased()
        for (pattern, replacement) in [(#"(~|\.{0,2})/[^\s:'"]+"#, "<path>"), (#"\b[0-9a-f]{7,}\b"#, "#"), (#"\d+"#, "#"), (#"\s+"#, " ")] {
            normalised = normalised.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(normalised.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    static let fillerWords: Set<String> = ["no", "nope", "don't", "dont", "do", "not", "stop", "wrong", "that's", "thats", "actually",
                                           "please", "the", "a", "an", "it", "it's", "its", "you", "i", "to", "and", "is",
                                           "that", "this", "these", "those", "like", "just", "again"]

    /// A correction's first six words that matter.
    static func correctionWords(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
            .prefix(6).joined(separator: " ")
    }
}

/// One piece of a candidate's evidence: which session, and what happened.
public struct LessonEvidence: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var sessionName: String
    public var kind: SessionDigest.Evidence.Kind
    public var text: String
    public var at: Date

    public init(sessionID: UUID, sessionName: String, kind: SessionDigest.Evidence.Kind, text: String, at: Date) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.kind = kind
        self.text = text
        self.at = at
    }
}

/// A lesson waiting to become a skill (kept in `skills.json`).
public struct LessonCandidate: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Gathering evidence.
        case collecting
        /// Manual mode: "Draft a skill from this?" waits in Needs You.
        case offered
        /// A draft waits in Needs You for you to approve.
        case proposed
    }

    public var id = UUID()
    public var signature: String
    /// The latest follow-up's words for it.
    public var summary: String
    /// Newest last, at most `maxEvidence`.
    public var evidence: [LessonEvidence]
    /// Every session it came up in, oldest first (at most `maxSessions`).
    /// Counted apart from the evidence, which keeps only its newest items,
    /// so a hold-back's "n more sessions" can always be reached.
    public var sessionIDs: [UUID]
    /// You told Claude to remember it: drafted straight away, once.
    public var remember: Bool
    public var state: State = .collecting
    /// After a draft that wasn't kept (Not Now, nothing worth a skill, or
    /// one that failed its checks), how many sessions must show it before
    /// it's drafted again.
    public var heldUntilSessions: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public static let maxEvidence = 10
    public static let maxSessions = 200
    /// Sessions that must show a lesson before a skill is drafted from it.
    public static let sessionsToDraft = 2

    public init(signature: String, summary: String, evidence: [LessonEvidence], remember: Bool, at date: Date) {
        self.signature = signature
        self.summary = summary
        self.evidence = evidence
        var sessions: [UUID] = []
        for item in evidence where !sessions.contains(item.sessionID) { sessions.append(item.sessionID) }
        sessionIDs = sessions
        self.remember = remember
        createdAt = date
        updatedAt = date
    }

    /// How many sessions it came up in.
    public var sessionCount: Int { sessionIDs.count }

    /// Gathering, and either you said to remember it or enough sessions show it.
    public var qualifies: Bool {
        state == .collecting && (remember || sessionCount >= max(LessonCandidate.sessionsToDraft, heldUntilSessions ?? 0))
    }

    /// Back to gathering after a draft that wasn't kept, until `more`
    /// sessions beyond today's show it.
    public mutating func holdBack(more: Int) {
        state = .collecting
        remember = false
        heldUntilSessions = sessionCount + more
    }

    private enum CodingKeys: String, CodingKey {
        case id, signature, summary, evidence, sessionIDs, remember, state, heldUntilSessions, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        signature = try c.decode(String.self, forKey: .signature)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        evidence = NeedsYouData.decodeEach(LessonEvidence.self, c, .evidence).read
        let sessions = NeedsYouData.decodeEach(UUID.self, c, .sessionIDs).read
        var fromEvidence: [UUID] = []
        for item in evidence where !fromEvidence.contains(item.sessionID) { fromEvidence.append(item.sessionID) }
        sessionIDs = sessions.isEmpty ? fromEvidence : sessions
        remember = try c.decodeIfPresent(Bool.self, forKey: .remember) ?? false
        // An unknown state from a later build goes back to gathering.
        state = ((try? c.decodeIfPresent(State.self, forKey: .state)) ?? nil) ?? .collecting
        heldUntilSessions = try? c.decodeIfPresent(Int.self, forKey: .heldUntilSessions)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

extension SkillsData {
    /// Most candidates kept per project; the oldest still gathering go first.
    public static let maxCandidates = 200

    /// Adds a follow-up's lessons: evidence joins the candidate with the
    /// same signature, or starts a new one. Returns the candidates touched.
    @discardableResult
    public mutating func add(_ findings: [LessonFinding], sessionID: UUID, sessionName: String, at date: Date) -> [UUID] {
        var touched: [UUID] = []
        for finding in findings {
            let evidence = finding.evidence.map {
                LessonEvidence(sessionID: sessionID, sessionName: sessionName, kind: $0.kind, text: $0.text, at: date)
            }
            if let index = candidates.firstIndex(where: { $0.signature == finding.signature }) {
                var candidate = candidates[index]
                for item in evidence where !candidate.evidence.contains(where: { $0.sessionID == item.sessionID && $0.text == item.text }) {
                    candidate.evidence.append(item)
                }
                if candidate.evidence.count > LessonCandidate.maxEvidence {
                    candidate.evidence.removeFirst(candidate.evidence.count - LessonCandidate.maxEvidence)
                }
                if !candidate.sessionIDs.contains(sessionID) {
                    candidate.sessionIDs.append(sessionID)
                    if candidate.sessionIDs.count > LessonCandidate.maxSessions {
                        candidate.sessionIDs.removeFirst(candidate.sessionIDs.count - LessonCandidate.maxSessions)
                    }
                }
                candidate.summary = finding.summary
                candidate.remember = candidate.remember || finding.remember
                candidate.updatedAt = date
                candidates[index] = candidate
                touched.append(candidate.id)
            } else {
                let candidate = LessonCandidate(signature: finding.signature, summary: finding.summary, evidence: evidence,
                                                remember: finding.remember, at: date)
                candidates.append(candidate)
                touched.append(candidate.id)
            }
        }
        while candidates.count > SkillsData.maxCandidates,
              let oldest = candidates.indices.filter({ candidates[$0].state == .collecting })
                .min(by: { candidates[$0].updatedAt < candidates[$1].updatedAt }) {
            candidates.remove(at: oldest)
        }
        return touched
    }
}

// MARK: - Lessons in the follow-up's reply

extension FollowUpJob {
    /// Lessons kept from one reply, at most.
    public static let maxLessons = 3

    /// Words in a correction that ask Claude to remember something. "Always"
    /// and "never" only count before a verb, so "no, never mind" doesn't.
    static let rememberPattern = try! NSRegularExpression(
        pattern: #"\b(remember|next time|from now on|in future|going forward)\b|\b(always|never)\s+(use|run|do|call|add|put|write|check|commit|push|make|edit|ask|test|leave|skip|start|open|change|delete|create)\b"#,
        options: [.caseInsensitive])

    /// The reply's lessons that cite real evidence. Refs are looked up in
    /// the call's own map; a lesson with none that resolve is dropped.
    /// `remember` only stands when a cited correction asks for it.
    public static func lessons(from reply: JSONValue, evidence: [String: SessionDigest.Evidence]) -> [LessonFinding] {
        lessonsAndDrops(from: reply, evidence: evidence).lessons
    }

    /// The lessons, and how many were dropped for citing nothing that
    /// resolves (or nothing a signature can be made from), for the log.
    public static func lessonsAndDrops(from reply: JSONValue, evidence: [String: SessionDigest.Evidence])
        -> (lessons: [LessonFinding], dropped: Int) {
        var findings: [LessonFinding] = []
        var dropped = 0
        for raw in reply["lessons"]?.arrayValue ?? [] {
            guard findings.count < maxLessons else { break }
            let summary = raw["summary"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cited = (raw["evidence"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap { evidence[$0] } }
            var unique: [SessionDigest.Evidence] = []
            for item in cited where !unique.contains(item) { unique.append(item) }
            guard !summary.isEmpty else { continue }
            guard !unique.isEmpty, let signature = LessonSignature.of(unique) else {
                dropped += 1
                continue
            }
            let asked = raw["remember"]?.boolValue == true && unique.contains { item in
                item.kind == .correction
                    && rememberPattern.firstMatch(in: item.text, range: NSRange(item.text.startIndex..., in: item.text)) != nil
            }
            findings.append(LessonFinding(summary: String(summary.prefix(300)), evidence: unique, remember: asked, signature: signature))
        }
        return (findings, dropped)
    }
}
