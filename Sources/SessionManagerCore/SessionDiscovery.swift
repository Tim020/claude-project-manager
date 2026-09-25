import Foundation

/// A Claude Code session found on disk under `~/.claude/projects`.
public struct DiscoveredSession: Equatable, Sendable {
    public var claudeSessionID: String
    public var title: String
    public var firstPrompt: String?
    public var summary: String
    public var model: String?
    public var workingDirectory: String
    public var lastActivity: Date
    public var pullRequestURLs: [String]
    public var status: SessionStatus

    public init(claudeSessionID: String, title: String, firstPrompt: String?, summary: String, model: String?,
                workingDirectory: String, lastActivity: Date, pullRequestURLs: [String], status: SessionStatus) {
        self.claudeSessionID = claudeSessionID
        self.title = title
        self.firstPrompt = firstPrompt
        self.summary = summary
        self.model = model
        self.workingDirectory = workingDirectory
        self.lastActivity = lastActivity
        self.pullRequestURLs = pullRequestURLs
        self.status = status
    }

    public var role: SessionRole { SessionRole.infer(fromName: title) }

    public func makeSession(projectID: UUID) -> Session {
        var session = Session(projectID: projectID, claudeSessionID: claudeSessionID, hasConversation: true, name: title,
                              role: role, workingDirectory: workingDirectory, status: status, summary: summary, model: model,
                              pullRequestURLs: pullRequestURLs, createdAt: lastActivity, lastActivity: lastActivity)
        session.needsAction = status == .awaitingInput ? summary : nil
        return session
    }
}

/// Reads Claude Code's own session store so existing sessions for a project
/// show up in the app, and loads their history for display.
public struct SessionDiscovery: Sendable {
    public static let maxTitleLength = 60

    public let claudeHome: URL

    public init(claudeHome: URL) {
        self.claudeHome = claudeHome
    }

    public static var defaultClaudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// Claude Code stores a project's sessions in a directory named after its
    /// path with every non-alphanumeric character replaced by `-`.
    public static func directoryName(forProjectPath path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public func projectDirectory(for projectPath: String) -> URL {
        claudeHome.appendingPathComponent("projects").appendingPathComponent(SessionDiscovery.directoryName(forProjectPath: projectPath))
    }

    public func historyFile(projectPath: String, claudeSessionID: String) -> URL {
        projectDirectory(for: projectPath).appendingPathComponent("\(claudeSessionID).jsonl")
    }

    /// All sessions with at least one real prompt, newest first.
    public func discover(projectPath: String) throws -> [DiscoveredSession] {
        let directory = projectDirectory(for: projectPath)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }

        return files.compactMap { file -> DiscoveredSession? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return SessionDiscovery.summarize(lines: text.split(separator: "\n").map(String.init),
                                              claudeSessionID: file.deletingPathExtension().lastPathComponent,
                                              fallbackDate: modified, defaultWorkingDirectory: projectPath)
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Events from a session's history file, suitable for `TranscriptBuilder`.
    public func loadHistory(projectPath: String, claudeSessionID: String) throws -> [StreamEvent] {
        let file = historyFile(projectPath: projectPath, claudeSessionID: claudeSessionID)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n").compactMap { StreamEventParser.parse(String($0)) }
    }

    static func summarize(lines: [String], claudeSessionID: String, fallbackDate: Date, defaultWorkingDirectory: String = "") -> DiscoveredSession? {
        var customTitle: String?, agentName: String?, aiTitle: String?, conversationSummary: String?
        var firstPrompt: String?
        var lastAssistantText: String?
        var model: String?
        var cwd: String?
        var latest: Date?
        var pullRequests: [String] = []
        var postTurnCategory: String?

        func addPullRequests(_ text: String) {
            for url in PullRequestDetector.urls(in: text) where !pullRequests.contains(url) { pullRequests.append(url) }
        }

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let type = record["type"]?.stringValue
            else { continue }

            if let stamp = record["timestamp"]?.stringValue, let date = parseDate(stamp) {
                latest = max(latest ?? date, date)
            }
            if cwd == nil, let value = record["cwd"]?.stringValue { cwd = value }

            switch StreamEventParser.parse(record: record, type: type) {
            case .customTitle(let title): customTitle = nonEmpty(title)
            case .conversationSummary(let summary): conversationSummary = nonEmpty(summary)
            case .other("ai-title"): aiTitle = nonEmpty(record["aiTitle"]?.stringValue)
            case .other("agent-name"): agentName = nonEmpty(record["agentName"]?.stringValue)
            case .postTurnSummary(let category, _, _): postTurnCategory = category
            case .user(let blocks, false):
                for block in blocks {
                    switch block {
                    case .text(let text):
                        if firstPrompt == nil { firstPrompt = TranscriptBuilder.cleanPrompt(text) }
                    case .toolResult(_, let content, _):
                        addPullRequests(content)
                    default: break
                    }
                }
            case .assistant(let blocks, false):
                if let value = record["message"]?["model"]?.stringValue, !value.hasPrefix("<") { model = value }
                for case .text(let text) in blocks {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    lastAssistantText = trimmed
                    addPullRequests(trimmed)
                }
            default:
                break
            }
        }

        guard let prompt = firstPrompt else { return nil }

        let status: SessionStatus
        if let postTurnCategory {
            status = postTurnCategory == "blocked" ? .awaitingInput : .completed
        } else {
            status = lastAssistantText?.hasSuffix("?") == true ? .awaitingInput : .completed
        }

        let title = customTitle ?? agentName ?? aiTitle ?? conversationSummary ?? truncateAtWord(firstLine(prompt), to: maxTitleLength)
        return DiscoveredSession(
            claudeSessionID: claudeSessionID,
            title: title,
            firstPrompt: prompt,
            summary: lastAssistantText.map { ToolSummary.truncate(TranscriptBuilder.firstLine($0), to: SessionReducer.maxSummaryLength) } ?? "",
            model: model,
            workingDirectory: cwd ?? defaultWorkingDirectory,
            lastActivity: latest ?? fallbackDate,
            pullRequestURLs: pullRequests,
            status: status)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func firstLine(_ text: String) -> String {
        TranscriptBuilder.firstLine(text)
    }

    static func truncateAtWord(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        var cut = String(text.prefix(length - 1))
        if let space = cut.lastIndex(of: " "), text[text.index(text.startIndex, offsetBy: length - 1)] != " " {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

extension Workspace {
    /// Merges sessions found on disk into a project. New ones land in Unfiled;
    /// known ones get fresher summary/status unless they are live (`skipping`).
    /// Returns the number of sessions added.
    @discardableResult
    public mutating func importDiscovered(_ discovered: [DiscoveredSession], into projectID: UUID, skipping live: Set<UUID>) -> Int {
        guard project(projectID) != nil else { return 0 }
        var added = 0
        for found in discovered {
            if let existing = session(claudeSessionID: found.claudeSessionID) {
                guard !live.contains(existing.id), found.lastActivity >= existing.lastActivity else { continue }
                updateSession(existing.id) { session in
                    if !found.summary.isEmpty { session.summary = found.summary }
                    session.status = found.status
                    session.needsAction = found.status == .awaitingInput ? found.summary : nil
                    session.lastActivity = found.lastActivity
                    session.hasConversation = true
                    if let model = found.model { session.model = model }
                    for url in found.pullRequestURLs where !session.pullRequestURLs.contains(url) {
                        session.pullRequestURLs.append(url)
                    }
                }
            } else {
                try? addSession(found.makeSession(projectID: projectID))
                added += 1
            }
        }
        return added
    }
}
