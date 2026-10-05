import Foundation

public enum HookEventName: Hashable, Sendable {
    case sessionStart, userPromptSubmit, preToolUse, postToolUse, notification, stop, sessionEnd
    /// A tool ran and failed (a Bash command exiting non-zero, a missing file).
    case postToolUseFailure
    /// A turn ended with an API error. It comes instead of `Stop`.
    case stopFailure
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "SessionStart": self = .sessionStart
        case "UserPromptSubmit": self = .userPromptSubmit
        case "PreToolUse": self = .preToolUse
        case "PostToolUse": self = .postToolUse
        case "Notification": self = .notification
        case "Stop": self = .stop
        case "SessionEnd": self = .sessionEnd
        case "PostToolUseFailure": self = .postToolUseFailure
        case "StopFailure": self = .stopFailure
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .sessionStart: return "SessionStart"
        case .userPromptSubmit: return "UserPromptSubmit"
        case .preToolUse: return "PreToolUse"
        case .postToolUse: return "PostToolUse"
        case .notification: return "Notification"
        case .stop: return "Stop"
        case .sessionEnd: return "SessionEnd"
        case .postToolUseFailure: return "PostToolUseFailure"
        case .stopFailure: return "StopFailure"
        case .other(let name): return name
        }
    }
}

/// A Claude Code hook invocation, as written by `HookSettings`' command.
public struct HookEvent: Equatable, Sendable {
    public var appSessionID: UUID
    public var name: HookEventName
    public var claudeSessionID: String?
    public var prompt: String?
    public var message: String?
    public var notificationType: String?
    public var lastAssistantMessage: String?
    public var toolName: String?
    public var toolOutput: String?
    public var toolInput: [String: JSONValue]?
    public var source: String?
    public var reason: String?
    /// PostToolUseFailure: the tool's error. StopFailure: the kind of API
    /// error ("authentication_failed"). A plain string in both.
    public var error: String?
    /// PostToolUseFailure: the user stopped the tool (Esc), so it didn't fail.
    public var isInterrupt = false
    /// Stop: the ids of the session's background tasks (shell commands,
    /// Monitors, subagents) still running as the turn ended. Each one wakes
    /// the session with a new turn when it finishes. Nil from a CLI that
    /// doesn't report them (`background_tasks`, seen with 2.1.289).
    public var backgroundTaskIDs: [String]?

    public init(appSessionID: UUID, name: HookEventName) {
        self.appSessionID = appSessionID
        self.name = name
    }
}

public enum HookEventParser {
    /// Parses `<app session UUID>\t<hook JSON>`.
    public static func parse(_ line: String) -> HookEvent? {
        guard let tab = line.firstIndex(of: "\t"),
              let id = UUID(uuidString: String(line[..<tab])),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line[line.index(after: tab)...].utf8)),
              let name = json["hook_event_name"]?.stringValue
        else { return nil }

        var event = HookEvent(appSessionID: id, name: HookEventName(rawValue: name))
        event.claudeSessionID = json["session_id"]?.stringValue
        event.prompt = json["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.message = json["message"]?.stringValue
        event.notificationType = json["notification_type"]?.stringValue
        event.lastAssistantMessage = json["last_assistant_message"]?.stringValue
        event.toolName = json["tool_name"]?.stringValue
        event.toolOutput = json["tool_response"]?["stdout"]?.stringValue ?? json["tool_response"]?.stringValue
        event.toolInput = json["tool_input"]?.objectValue
        event.source = json["source"]?.stringValue
        event.reason = json["reason"]?.stringValue
        event.error = json["error"]?.stringValue
        event.isInterrupt = json["is_interrupt"]?.boolValue ?? false
        event.backgroundTaskIDs = json["background_tasks"]?.arrayValue?.compactMap { task in
            (task["status"]?.stringValue ?? "running") == "running" ? task["id"]?.stringValue : nil
        }
        return event
    }
}

/// Reads hook events appended to the log since the last read.
public struct HookEventTailer: Sendable {
    public let url: URL
    private var offset: UInt64 = 0
    private var buffer = LineBuffer()

    public init(url: URL, startAtEnd: Bool = false) {
        self.url = url
        if startAtEnd, let size = HookEventTailer.size(of: url) { offset = size }
    }

    public mutating func readNew() -> [HookEvent] {
        guard let size = HookEventTailer.size(of: url) else { return [] }
        if size < offset {
            // The log was truncated or replaced; start over.
            offset = 0
            buffer = LineBuffer()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            return buffer.append(data).compactMap(HookEventParser.parse)
        } catch {
            return []
        }
    }

    private static func size(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}

/// Maps hook events onto session status:
/// prompt / tool use → Working; permission request → Awaiting Input;
/// Stop → Completed, or Awaiting Input when Claude ended on a question, or
/// still Working while background tasks it started are running.
public enum HookReducer {
    public static let maxSummaryLength = 140

    public static func apply(_ event: HookEvent, to session: inout Session, now: Date) {
        if let id = event.claudeSessionID, !id.isEmpty { session.claudeSessionID = id }

        switch event.name {
        case .sessionStart:
            break
        case .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure:
            if event.name == .userPromptSubmit {
                session.hasConversation = true
                session.lastTurnFailed = false
            }
            session.status = .working
            session.needsAction = nil
            session.lastActivity = now
            if event.name == .postToolUse {
                let links = PullRequestActivity.links(toolName: event.toolName, input: event.toolInput, output: event.toolOutput ?? "")
                PullRequestLink.merge(links, into: &session.pullRequests)
            }
        case .notification:
            let message = event.message ?? ""
            let isIdleReminder = event.notificationType == "idle_prompt"
                || (event.notificationType == nil && message.lowercased().contains("waiting for your input"))
            guard !isIdleReminder else { return }
            session.status = .awaitingInput
            session.needsAction = message.isEmpty ? nil : message
            session.lastActivity = now
        case .stop:
            let text = event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                session.summary = ToolSummary.truncate(TranscriptBuilder.firstLine(text), to: maxSummaryLength)
            }
            session.backgroundTasks = event.backgroundTaskIDs ?? []
            if text.hasSuffix("?") {
                session.status = .awaitingInput
                session.needsAction = session.summary
            } else {
                // A task finishing starts a new turn, whose Stop reports again.
                session.status = session.backgroundTasks.isEmpty ? .completed : .working
                session.needsAction = nil
            }
            session.lastActivity = now
            session.lastTurnFailed = false
        case .stopFailure:
            // The turn ended (it comes instead of Stop), with an API error.
            session.backgroundTasks = event.backgroundTaskIDs ?? []
            session.status = session.backgroundTasks.isEmpty ? .completed : .working
            session.needsAction = nil
            session.lastTurnFailed = true
            let text = event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { session.summary = ToolSummary.truncate(TranscriptBuilder.firstLine(text), to: maxSummaryLength) }
            session.lastActivity = now
        case .sessionEnd:
            session.backgroundTasks = []
            if session.status == .working { session.status = .completed }
        case .other:
            break
        }
    }
}

public enum PullRequestDetector {
    private static let pattern = try! NSRegularExpression(pattern: #"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+"#)

    /// GitHub pull request URLs in order of first appearance, without duplicates.
    public static func urls(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let url = String(text[r])
            if !result.contains(url) { result.append(url) }
        }
        return result
    }

    public static func number(from url: String) -> Int? {
        url.split(separator: "/").last.flatMap { Int($0) }
    }
}
