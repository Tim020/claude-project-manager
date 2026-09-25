import Foundation

/// One Claude plan rate-limit window (the 5-hour session or the week).
public struct UsageWindow: Equatable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var fraction: Double { min(1, max(0, usedPercentage / 100)) }

    public var percentLabel: String { "\(Int(usedPercentage.rounded(.down)))%" }

    public func resetLabel(now: Date) -> String {
        guard let resetsAt else { return "" }
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
    public var usagePath: String
    public var userStatusLine: UserStatusLine?
    /// Re-run periodically so usage stays fresh while a session is idle.
    public static let refreshInterval = 60

    public init(usagePath: String, userStatusLine: UserStatusLine?) {
        self.usagePath = usagePath
        self.userStatusLine = userStatusLine
    }

    public var command: String {
        let path = ShellQuote.quote(usagePath)
        var command = #"input=$(cat); printf '%s' "$input" > \#(path).$$ && mv -f \#(path).$$ \#(path); "#
        if let user = userStatusLine {
            command += #"printf '%s' "$input" | sh -c \#(ShellQuote.quote(user.command))"#
        } else {
            command += ":"
        }
        return command
    }

    var settingsValue: JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(command),
            "refreshInterval": .number(Double(StatusLineCapture.refreshInterval)),
        ]
        if let padding = userStatusLine?.padding { object["padding"] = .number(Double(padding)) }
        return .object(object)
    }
}
