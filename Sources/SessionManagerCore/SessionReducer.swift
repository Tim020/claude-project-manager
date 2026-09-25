import Foundation

/// Transient, per-launch state for a session: its transcript and whether a
/// turn is in flight. Not persisted — history is reloaded from Claude Code's
/// own `.jsonl` files.
public struct SessionActivity: Equatable, Sendable {
    public var transcript: TranscriptBuilder
    public var isTurnActive = false
    /// What the agent is doing right now (from `task_summary`).
    public var liveDetail: String?
    var turnHadPostSummary = false

    public init(workingDirectory: String = "/") {
        transcript = TranscriptBuilder(workingDirectory: workingDirectory)
    }
}

/// Applies Claude Code events to a session's persisted fields and its
/// transient activity.
public enum SessionReducer {
    public static let maxSummaryLength = 140

    public static func promptSent(to session: inout Session, activity: inout SessionActivity, now: Date, prompt: String? = nil) {
        if let prompt { activity.transcript.appendPrompt(prompt) }
        session.status = .working
        session.needsAction = nil
        session.lastActivity = now
        activity.isTurnActive = true
        activity.turnHadPostSummary = false
    }

    public static func apply(_ event: StreamEvent, to session: inout Session, activity: inout SessionActivity, now: Date) {
        activity.transcript.apply(event)

        switch event {
        case .initialized(let sessionID, let model, _):
            if !sessionID.isEmpty { session.claudeSessionID = sessionID }
            if let model { session.model = model }
            session.hasConversation = true

        case .taskSummary(let detail):
            activity.liveDetail = detail

        case .postTurnSummary(let category, let detail, let needsAction):
            activity.turnHadPostSummary = true
            if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                session.summary = truncate(firstLine(detail))
            }
            switch category {
            case "working":
                if activity.isTurnActive { session.status = .working }
            case "blocked":
                session.status = .awaitingInput
                let needs = needsAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                session.needsAction = needs.isEmpty ? detail : needs
            default:
                session.status = .completed
                session.needsAction = nil
            }
            session.lastActivity = now

        case .assistant(let blocks, false):
            session.lastActivity = now
            for case .text(let text) in blocks { collectPullRequests(from: text, into: &session) }

        case .user(let blocks, false):
            for case .toolResult(_, let content, _) in blocks { collectPullRequests(from: content, into: &session) }

        case .result(let info):
            activity.isTurnActive = false
            activity.liveDetail = nil
            session.lastActivity = now
            if let text = info.text {
                collectPullRequests(from: text, into: &session)
            }
            if !activity.turnHadPostSummary {
                if let text = info.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    session.summary = truncate(firstLine(text))
                }
                if info.permissionDenials > 0 {
                    session.status = .awaitingInput
                } else if !info.isError, info.text?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") == true {
                    session.status = .awaitingInput
                } else {
                    session.status = .completed
                }
            }

        default:
            break
        }
    }

    public static func processExited(session: inout Session, activity: inout SessionActivity, exitCode: Int32, now: Date) {
        guard activity.isTurnActive else { return }
        activity.isTurnActive = false
        activity.liveDetail = nil
        activity.transcript.appendError("Claude Code exited unexpectedly (code \(exitCode))")
        session.status = .completed
        session.lastActivity = now
    }

    static func collectPullRequests(from text: String, into session: inout Session) {
        for url in PullRequestDetector.urls(in: text) where !session.pullRequestURLs.contains(url) {
            session.pullRequestURLs.append(url)
        }
    }

    static func firstLine(_ text: String) -> String {
        TranscriptBuilder.firstLine(text)
    }

    static func truncate(_ text: String) -> String {
        ToolSummary.truncate(text, to: maxSummaryLength)
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
