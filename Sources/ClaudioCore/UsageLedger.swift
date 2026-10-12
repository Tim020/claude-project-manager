import Foundation

// Usage, step 1: what's been read from each conversation's transcripts,
// saved in `usage.json` beside `state.json` so a relaunch reads only what's
// new. A conversation keeps its totals after its session is removed or
// deleted (and its transcripts with it), so removed sessions still count.

/// One Claude Code conversation's usage, by its id.
public struct ConversationUsage: Codable, Equatable, Sendable {
    public var projectID: UUID
    /// Claudio's session it belongs to (a session's `/clear`ed conversations
    /// are its too).
    public var sessionID: UUID?
    /// The session's name and folder when last seen, for once it's gone.
    public var sessionName: String
    public var folderID: UUID?
    /// Transcript path → how far it's been read.
    public var files: [String: TranscriptProgress]

    public init(projectID: UUID, sessionID: UUID?, sessionName: String, folderID: UUID?, files: [String: TranscriptProgress] = [:]) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.folderID = folderID
        self.files = files
    }

    enum CodingKeys: String, CodingKey { case projectID, sessionID, sessionName, folderID, files }

    /// Tolerant of fields added later; only the project is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        files = try c.decodeIfPresent([String: TranscriptProgress].self, forKey: .files) ?? [:]
    }

    /// Every file's hours, merged.
    public var buckets: [UsageBucket] {
        var merged: [String: UsageBucket] = [:]
        for bucket in files.values.flatMap(\.buckets) {
            merged["\(bucket.hour)|\(bucket.model)", default: UsageBucket(hour: bucket.hour, model: bucket.model, tokens: TokenCounts())]
                .tokens += bucket.tokens
        }
        return merged.values.sorted { ($0.hour, $0.model) < ($1.hour, $1.model) }
    }

    public var turns: Int { files.values.reduce(0) { $0 + $1.turns } }
}

extension UsageLedger {
    /// The targets' transcripts with lines that looked like replies but
    /// couldn't be read.
    func unreadableLines(in targets: [UsageScanTarget]) -> [String: Int] {
        var lines: [String: Int] = [:]
        for target in targets {
            for (path, file) in conversations[target.conversationID]?.files ?? [:] where file.unreadableLines > 0 {
                lines[path] = file.unreadableLines
            }
        }
        return lines
    }
}

public struct UsageLedger: Codable, Equatable, Sendable {
    /// Bumped when what's recorded changes; an older ledger is read afresh.
    public static let currentVersion = 1

    public var version = UsageLedger.currentVersion
    /// By Claude Code conversation id.
    public var conversations: [String: ConversationUsage] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        // Entries that don't decode are dropped and read again.
        let raw = try c.decodeIfPresent([String: FailableConversation].self, forKey: .conversations) ?? [:]
        conversations = raw.compactMapValues(\.value)
    }

    private struct FailableConversation: Decodable {
        var value: ConversationUsage?
        init(from decoder: Decoder) throws { value = try? ConversationUsage(from: decoder) }
    }
}

/// Where the usage ledger is kept.
public protocol UsageStoring: AnyObject, Sendable {
    /// Nil when there's none yet. Throws for one that can't be read,
    /// including one from another version.
    func load() throws -> UsageLedger?
    func save(_ ledger: UsageLedger) throws
    /// Moves a ledger that couldn't be read out of the way, so saving
    /// doesn't overwrite it (it may hold deleted sessions' only totals).
    /// Returns where it went (nil: there was nothing to move).
    func setAside(now: Date) throws -> URL?
}

public enum UsageLedgerError: Error, LocalizedError {
    case otherVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .otherVersion(let version):
            return "It's version \(version), and this Claudio reads version \(UsageLedger.currentVersion)."
        }
    }
}

/// Keeps the ledger in memory: the default, so tests never touch real files.
public final class MemoryUsageStore: UsageStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UsageLedger?
    public init(_ ledger: UsageLedger? = nil) { stored = ledger }
    public var ledger: UsageLedger? { lock.withLock { stored } }
    /// Makes `load` throw, as an unreadable file does (for tests).
    public var loadError: Error?
    /// What `setAside` moved (for tests).
    public private(set) var setAsideCount = 0
    public func load() throws -> UsageLedger? {
        try lock.withLock {
            if let loadError { throw loadError }
            return stored
        }
    }
    public func save(_ ledger: UsageLedger) throws { lock.withLock { stored = ledger } }
    public func setAside(now: Date) throws -> URL? {
        lock.withLock {
            loadError = nil
            setAsideCount += 1
        }
        return URL(fileURLWithPath: "/memory/usage.json.unreadable")
    }
}

/// `~/Library/Application Support/Claudio/usage.json`.
public final class UsageFileStore: UsageStoring, @unchecked Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        JSONFileStore.defaultURL.deletingLastPathComponent().appendingPathComponent("usage.json")
    }

    public func load() throws -> UsageLedger? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ledger = try JSONDecoder().decode(UsageLedger.self, from: Data(contentsOf: url))
        guard ledger.version == UsageLedger.currentVersion else { throw UsageLedgerError.otherVersion(ledger.version) }
        return ledger
    }

    /// `usage.json` → `usage-unreadable-<seconds since 1970>.json`, beside it.
    public func setAside(now: Date) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("usage-unreadable-\(Int(now.timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    public func save(_ ledger: UsageLedger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }
}

/// A conversation to read, with what's known of its session now.
public struct UsageScanTarget: Equatable, Sendable {
    public var conversationID: String
    public var projectID: UUID
    public var sessionID: UUID?
    public var sessionName: String
    public var folderID: UUID?
    public var files: [URL]

    public init(conversationID: String, projectID: UUID, sessionID: UUID?, sessionName: String, folderID: UUID?, files: [URL]) {
        self.conversationID = conversationID
        self.projectID = projectID
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.folderID = folderID
        self.files = files
    }
}

public enum UsageScanner {
    /// A conversation's transcripts: `<id>.jsonl` wherever its history is
    /// (`SessionDiscovery.historyItems`), and its subagents' under
    /// `<id>/subagents/`.
    public static func transcriptFiles(discovery: SessionDiscovery, projectPath: String, workingDirectory: String,
                                       conversationID: String, projectDirectories: [String]? = nil) -> [URL] {
        discovery.historyItems(projectPath: projectPath, workingDirectory: workingDirectory, claudeSessionID: conversationID,
                               projectDirectories: projectDirectories)
            .flatMap { item -> [URL] in
                if item.pathExtension == "jsonl" { return [item] }
                let subagents = item.appendingPathComponent("subagents")
                let names = (try? FileManager.default.contentsOfDirectory(atPath: subagents.path)) ?? []
                return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { subagents.appendingPathComponent($0) }
            }
    }

    public struct Result: Equatable, Sendable {
        /// Transcripts that are there but couldn't be read, with their project.
        public var unreadable: [String: UUID] = [:]
        /// Transcripts with lines that looked like replies but couldn't be
        /// read (their tokens aren't counted), and how many such lines each has.
        public var unreadableLines: [String: Int] = [:]
        /// How many files had something new.
        public var filesRead = 0
    }

    /// Reads what's new in each target's transcripts into the ledger, in the
    /// order given (the oldest session first, so a copy's repeated replies
    /// stay with the original). `progress` is told (done, total) as files
    /// are read. Files that have gone keep what was read from them.
    public static func scan(_ targets: [UsageScanTarget], into ledger: inout UsageLedger,
                            chunkSize: Int = 8 * 1024 * 1024, progress: (Int, Int) -> Void = { _, _ in }) -> Result {
        var result = Result()
        var pending: [(target: UsageScanTarget, url: URL, size: Int)] = []
        for target in targets {
            var conversation = ledger.conversations[target.conversationID]
                ?? ConversationUsage(projectID: target.projectID, sessionID: nil, sessionName: target.sessionName, folderID: nil)
            conversation.projectID = target.projectID
            conversation.sessionID = target.sessionID
            conversation.sessionName = target.sessionName
            conversation.folderID = target.folderID
            if ledger.conversations[target.conversationID] != conversation { ledger.conversations[target.conversationID] = conversation }
            for url in target.files {
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                    // Gone (what was read from it stays), or there but not
                    // readable, which is reported like a read that fails.
                    if FileManager.default.fileExists(atPath: url.path) { result.unreadable[url.path] = target.projectID }
                    continue
                }
                if conversation.files[url.path]?.size != size.intValue { pending.append((target, url, size.intValue)) }
            }
        }
        guard !pending.isEmpty else {
            result.unreadableLines = ledger.unreadableLines(in: targets)
            return result
        }

        // Which file counted each reply, per project, to count copies once.
        var owners: [UUID: [String: String]] = [:]
        for project in Set(pending.map(\.target.projectID)) {
            var map: [String: String] = [:]
            for conversation in ledger.conversations.values where conversation.projectID == project {
                for (path, file) in conversation.files {
                    for id in file.messageIDs where map[id] == nil { map[id] = path }
                }
            }
            owners[project] = map
        }

        for (done, item) in pending.enumerated() {
            progress(done, pending.count)
            let path = item.url.path
            var file = ledger.conversations[item.target.conversationID]?.files[path] ?? TranscriptProgress()
            if file.offset < 0 || item.size < file.offset { file = TranscriptProgress() }
            let project = item.target.projectID
            do {
                // Looked up in place: a copy of the project's map per file
                // would make a first scan of many files quadratic.
                try read(item.url, into: &file, countsTurns: !path.contains("/subagents/"), chunkSize: chunkSize) { id in
                    owners[project]?[id].map { $0 != path } ?? false
                }
            } catch {
                result.unreadable[path] = item.target.projectID
                continue
            }
            file.size = item.size
            for id in file.messageIDs where owners[item.target.projectID]?[id] == nil { owners[item.target.projectID]?[id] = path }
            ledger.conversations[item.target.conversationID]?.files[path] = file
            result.filesRead += 1
        }
        progress(pending.count, pending.count)
        result.unreadableLines = ledger.unreadableLines(in: targets)
        return result
    }

    /// Reads a file from where it got to, a chunk at a time. A line longer
    /// than a chunk (a pasted image) gets a bigger chunk.
    static func read(_ url: URL, into file: inout TranscriptProgress, countsTurns: Bool, chunkSize: Int = 8 * 1024 * 1024,
                     isCountedElsewhere: (String) -> Bool) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var chunkSize = max(1, chunkSize)
        while true {
            try handle.seek(toOffset: UInt64(max(0, file.offset)))
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return }
            let before = file.offset
            file.read(data, countsTurns: countsTurns, isCountedElsewhere: isCountedElsewhere)
            if data.count < chunkSize { return }
            if file.offset == before { chunkSize *= 2 }
        }
    }
}
