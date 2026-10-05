import Foundation

/// A background task a session's turn left running: a backgrounded shell
/// command, a Monitor or a subagent. It keeps the session Working until it
/// finishes (see `HookReducer`).
public struct BackgroundTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// "shell" or "subagent" from the Stop hook; "shell", "monitor" or
    /// "agent" from a job state.
    public var kind: String?
    public var description: String?
    /// When Claudio first saw it running (the Stop that listed it), or when
    /// it started (from a job state).
    public var since: Date

    public init(id: String, kind: String? = nil, description: String? = nil, since: Date) {
        self.id = id
        self.kind = kind
        self.description = description
        self.since = since
    }

    /// "subagent", "Monitor" or "command".
    public var noun: String {
        switch kind {
        case "subagent", "agent": return "subagent"
        case "monitor": return "Monitor"
        default: return "command"
        }
    }
}

/// One entry of the Stop hook's `background_tasks`.
public struct BackgroundTaskReport: Equatable, Sendable {
    public var id: String
    public var kind: String?
    public var description: String?

    public init(id: String, kind: String? = nil, description: String? = nil) {
        self.id = id
        self.kind = kind
        self.description = description
    }
}

public enum BackgroundTasks {
    /// After this long a session's tasks are shown in Needs You: a dev
    /// server or `tail -f` never finishes, and you may want to mark it
    /// finished. Monitors time out after 30 minutes by default.
    public static let longRunningAfter: TimeInterval = 30 * 60

    /// When the longest-running of `tasks` started.
    public static func runningSince(_ tasks: [BackgroundTask]) -> Date? {
        tasks.map(\.since).min()
    }

    public static func isLongRunning(_ session: Session, now: Date) -> Bool {
        guard let since = runningSince(session.backgroundTasks) else { return false }
        return now.timeIntervalSince(since) >= longRunningAfter
    }

    /// "1 background task", "3 background tasks".
    public static func count(_ tasks: [BackgroundTask]) -> String {
        tasks.count == 1 ? "1 background task" : "\(tasks.count) background tasks"
    }

    /// "12 min", "2 h 5 min".
    public static func duration(from since: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "Run backend tests (command, 12 min)".
    public static func line(_ task: BackgroundTask, now: Date) -> String {
        let name = task.description.flatMap { $0.isEmpty ? nil : $0 } ?? task.id
        return "\(name) (\(task.noun), \(duration(from: task.since, to: now)))"
    }

    /// The session row's pill tooltip.
    public static func help(_ tasks: [BackgroundTask], now: Date) -> String {
        "\(count(tasks)) running, so it stays Working until they finish:\n"
            + tasks.map { "• " + line($0, now: now) }.joined(separator: "\n")
    }
}

/// The `<task-notification>` prompt a finishing task wakes its session with.
public enum TaskNotification {
    private static let block = try! NSRegularExpression(pattern: #"<task-notification>(.*?)</task-notification>"#, options: [.dotMatchesLineSeparators])
    private static let taskID = try! NSRegularExpression(pattern: #"<task-id>([^<]+)</task-id>"#)

    /// The tasks the prompt says have ended: notifications with a
    /// `<status>` (completed, failed…). A Monitor's events have none, and
    /// its task goes on. A subagent may notify again if it's resumed.
    public static func endedTaskIDs(in prompt: String) -> [String] {
        guard prompt.contains("<task-notification>") else { return [] }
        let range = NSRange(prompt.startIndex..., in: prompt)
        return block.matches(in: prompt, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: prompt) else { return nil }
            let body = String(prompt[r])
            guard body.contains("<status>"),
                  let id = taskID.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let idRange = Range(id.range(at: 1), in: body) else { return nil }
            return String(body[idRange])
        }
    }
}

extension Session {
    /// Its process has gone, and its tasks with it.
    mutating func forgetBackgroundTasks() {
        backgroundTasks = []
        finishedBackgroundTasks = []
    }

    /// Takes a Stop hook's report: each task keeps the time it was first
    /// seen, and ones you marked finished don't count. Marks for tasks no
    /// longer reported are forgotten.
    mutating func setBackgroundTasks(_ reported: [BackgroundTaskReport], now: Date) {
        let reportedIDs = Set(reported.map(\.id))
        finishedBackgroundTasks.removeAll { !reportedIDs.contains($0) }
        let seen = Dictionary(backgroundTasks.map { ($0.id, $0.since) }, uniquingKeysWith: { first, _ in first })
        backgroundTasks = reported.filter { !finishedBackgroundTasks.contains($0.id) }.map {
            BackgroundTask(id: $0.id, kind: $0.kind, description: $0.description, since: seen[$0.id] ?? now)
        }
    }
}
