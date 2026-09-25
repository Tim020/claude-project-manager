import Foundation

/// One Claude plan rate-limit window (the 5-hour session or the week).
public struct UsageWindow: Equatable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date?
    /// Reset time as `claude /usage` words it, when there's no timestamp.
    public var resetText: String?

    public init(usedPercentage: Double, resetsAt: Date?, resetText: String? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.resetText = resetText
    }

    public var fraction: Double { min(1, max(0, usedPercentage / 100)) }

    public var percentLabel: String { "\(Int(usedPercentage.rounded(.down)))%" }

    public func resetLabel(now: Date) -> String {
        guard let resetsAt else { return resetText.map { "resets \($0)" } ?? "" }
        let minutes = max(1, Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "resets in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "resets in \(hours)h \(minutes % 60)m" }
        return "resets in \(hours / 24)d \(hours % 24)h"
    }
}

/// Plan usage as Claude Code reports it to status line commands.
public struct UsageSnapshot: Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var subscriptionType: String?
    public var updatedAt: Date

    /// Parses a status line input (`rate_limits.five_hour` / `seven_day`).
    public static func parse(_ data: Data, updatedAt: Date) -> UsageSnapshot? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let limits = value["rate_limits"] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let used = limits[key]?["used_percentage"]?.doubleValue else { return nil }
            return UsageWindow(usedPercentage: used, resetsAt: limits[key]?["resets_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) })
        }
        let snapshot = UsageSnapshot(fiveHour: window("five_hour"), sevenDay: window("seven_day"),
                                     subscriptionType: value["subscription_type"]?.stringValue, updatedAt: updatedAt)
        return snapshot.fiveHour == nil && snapshot.sevenDay == nil ? nil : snapshot
    }
}

extension UsageSnapshot {
    private static let usageLine = try! NSRegularExpression(pattern: #"^(Current session|Current week \(all models\)): (\d+(?:\.\d+)?)% used(?: · resets (.+))?$"#)

    /// Parses `claude -p /usage` output ("Current session: 56% used · resets 3pm").
    /// It needs no model call, so it works before any session has run.
    public static func parseUsageCommand(_ output: String, updatedAt: Date) -> UsageSnapshot? {
        var snapshot = UsageSnapshot(fiveHour: nil, sevenDay: nil, subscriptionType: nil, updatedAt: updatedAt)
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = usageLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let titleRange = Range(match.range(at: 1), in: line),
                  let percentRange = Range(match.range(at: 2), in: line),
                  let percent = Double(line[percentRange])
            else { continue }
            let reset = Range(match.range(at: 3), in: line).map { String(line[$0]) }
            let window = UsageWindow(usedPercentage: percent, resetsAt: nil, resetText: reset)
            if line[titleRange] == "Current session" { snapshot.fiveHour = window } else { snapshot.sevenDay = window }
        }
        return snapshot.fiveHour == nil && snapshot.sevenDay == nil ? nil : snapshot
    }
}

/// How full a session's context window is, from its status line input.
public struct ContextUsage: Equatable, Sendable {
    public var usedPercentage: Double
    public var windowSize: Int?
    public var inputTokens: Int?

    public init(usedPercentage: Double, windowSize: Int?, inputTokens: Int?) {
        self.usedPercentage = usedPercentage
        self.windowSize = windowSize
        self.inputTokens = inputTokens
    }

    public static func parse(_ data: Data) -> ContextUsage? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let window = value["context_window"], let used = window["used_percentage"]?.doubleValue
        else { return nil }
        return ContextUsage(usedPercentage: used,
                            windowSize: window["context_window_size"]?.doubleValue.map { Int($0) },
                            inputTokens: window["total_input_tokens"]?.doubleValue.map { Int($0) })
    }

    public var fraction: Double { min(1, max(0, usedPercentage / 100)) }
    public var label: String { "\(Int(usedPercentage.rounded()))%" }

    public var detail: String {
        guard let windowSize else { return "\(label) of the context window used" }
        let used = inputTokens.map(ContextUsage.compact) ?? label
        return "\(used) of \(ContextUsage.compact(windowSize)) tokens"
    }

    static func compact(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? "\(tokens / 1_000_000)M" : tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)"
    }
}

/// The user's own status line from `~/.claude/settings.json`, so sessions the
/// app launches still show it.
public struct UserStatusLine: Equatable, Sendable {
    public var command: String
    public var padding: Int?

    public init(command: String, padding: Int?) {
        self.command = command
        self.padding = padding
    }

    public static func load(from settingsFile: URL) -> UserStatusLine? {
        guard let data = try? Data(contentsOf: settingsFile),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let command = value["statusLine"]?["command"]?.stringValue, !command.isEmpty
        else { return nil }
        return UserStatusLine(command: command, padding: value["statusLine"]?["padding"]?.doubleValue.map { Int($0) })
    }
}

/// A status line command for the sessions the app launches: it saves Claude
/// Code's status line input (which includes plan usage) for the app, then runs
/// the user's own status line command, if any, so their status line is unchanged.
public struct StatusLineCapture: Equatable, Sendable {
    /// Where each session's latest status line input is kept (for its context
    /// window), as `<directory>/<app session id>.json`.
    public var statusDirectory: String?
    public var usagePath: String
    public var userStatusLine: UserStatusLine?
    /// Re-run periodically so usage stays fresh while a session is idle.
    public static let refreshInterval = 60

    public init(statusDirectory: String? = nil, usagePath: String, userStatusLine: UserStatusLine?) {
        self.statusDirectory = statusDirectory
        self.usagePath = usagePath
        self.userStatusLine = userStatusLine
    }

    public var command: String { command(for: nil) }

    public func command(for appSessionID: UUID?) -> String {
        let path = ShellQuote.quote(usagePath)
        var command = #"input=$(cat); printf '%s' "$input" > \#(path).$$ && mv -f \#(path).$$ \#(path); "#
        if let statusDirectory, let appSessionID {
            let directory = ShellQuote.quote(statusDirectory)
            let file = ShellQuote.quote((statusDirectory as NSString).appendingPathComponent("\(appSessionID.uuidString).json"))
            command += #"mkdir -p \#(directory) && printf '%s' "$input" > \#(file).$$ && mv -f \#(file).$$ \#(file); "#
        }
        if let user = userStatusLine {
            command += #"printf '%s' "$input" | sh -c \#(ShellQuote.quote(user.command))"#
        } else {
            command += ":"
        }
        return command
    }

    func settingsValue(for appSessionID: UUID?) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(command(for: appSessionID)),
            "refreshInterval": .number(Double(StatusLineCapture.refreshInterval)),
        ]
        if let padding = userStatusLine?.padding { object["padding"] = .number(Double(padding)) }
        return .object(object)
    }
}
