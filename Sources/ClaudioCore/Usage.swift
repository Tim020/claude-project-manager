import Foundation

/// One Claude plan rate-limit window (the 5-hour session or the week).
public struct UsageWindow: Equatable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date?
    /// Reset time as `claude /usage`'s text words it. Shown only when it
    /// couldn't be read into `resetsAt`.
    public var resetText: String?

    public init(usedPercentage: Double, resetsAt: Date?, resetText: String? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.resetText = resetText
    }

    public var fraction: Double { min(1, max(0, usedPercentage / 100)) }

    public var percentLabel: String { "\(Int(usedPercentage.rounded(.down)))%" }

    /// "resets in 2h 14m" within a day, "resets Sep 29 at 9am" further off.
    public func resetLabel(now: Date, timeZone: TimeZone = .current) -> String {
        guard let resetsAt else { return resetText.map { "resets \($0)" } ?? "" }
        return "resets \(UsageWindow.when(resetsAt, now: now, timeZone: timeZone, soon: "in"))"
    }

    /// A reset time as "<soon> 2h 14m" within a day, else as the date and
    /// time ("Sep 29 at 9am"), so every window reads the same way.
    static func when(_ date: Date, now: Date, timeZone: TimeZone, soon: String) -> String {
        date.timeIntervalSince(now) < 86400
            ? "\(soon) \(duration(until: date, now: now))"
            : dateTime(date, timeZone: timeZone)
    }

    /// "14m", "2h 14m" or "3d 4h", rounded up to the minute.
    static func duration(until date: Date, now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// "Sep 29 at 9am" or "Sep 29 at 4:49pm", worded as Claude Code's `/usage`
    /// words it. Built by hand so it's the same in every locale and on Linux.
    static func dateTime(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        let clock = "\(hour % 12 == 0 ? 12 : hour % 12)" + (minute == 0 ? "" : String(format: ":%02d", minute))
        return "\(monthNames[(parts.month ?? 1) - 1]) \(parts.day ?? 1) at \(clock)\(hour < 12 ? "am" : "pm")"
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static let resetTextPattern = try! NSRegularExpression(
        pattern: #"^(?:([A-Za-z]{3})[a-z]*\.? (\d{1,2})(?:,| at) )?(\d{1,2})(?::(\d{2}))?(am|pm)(?: \(([^)]+)\))?$"#)

    /// The time in `/usage`'s reset text ("3:10pm (Europe/London)",
    /// "Sep 29, 9am (…)", "Sep 27 at 4:49am (…)"): its next occurrence from
    /// `now`, in the zone the text names (else `timeZone`). Nil for any other
    /// wording, which is then shown as it is.
    static func parseResetText(_ text: String, now: Date, timeZone: TimeZone = .current) -> Date? {
        guard let match = resetTextPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard let hour = group(3).flatMap(Int.init), (1...12).contains(hour), let meridiem = group(5) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group(6).flatMap(TimeZone.init(identifier:)) ?? timeZone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        parts.minute = group(4).flatMap(Int.init) ?? 0
        let hasDate = group(1) != nil
        if hasDate {
            guard let name = group(1), let month = monthNames.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  let day = group(2).flatMap(Int.init) else { return nil }
            parts.month = month + 1
            parts.day = day
        }
        guard let date = calendar.date(from: parts) else { return nil }
        // The text is to the minute, so a time within the last minute is a
        // reset that's due now, not tomorrow's (or, with a date, next year's).
        guard date.addingTimeInterval(60) <= now else { return date }
        return calendar.date(byAdding: hasDate ? .year : .day, value: 1, to: date)
    }

    /// The window as it stands at `now`: once its reset time has passed,
    /// nothing is used until the next reading.
    public func current(at now: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageWindow(usedPercentage: 0, resetsAt: nil)
    }
}

/// Usage credits ("extra usage"): pay-as-you-go spend that Claude Code draws
/// on once a plan limit is reached, if the account has it turned on.
public struct UsageCredits: Equatable, Sendable {
    public var isEnabled: Bool
    /// Amounts are in the currency's minor units (pence, cents), as reported.
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    /// Percentage of the monthly limit spent.
    public var utilization: Double?
    public var currency: String?

    public init(isEnabled: Bool, monthlyLimit: Double?, usedCredits: Double?, utilization: Double?, currency: String?) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
    }

    private var usedPercentage: Double? {
        if let utilization { return utilization }
        guard let usedCredits, let monthlyLimit, monthlyLimit > 0 else { return nil }
        return usedCredits / monthlyLimit * 100
    }

    public var fraction: Double { min(1, max(0, (usedPercentage ?? 0) / 100)) }

    /// The monthly limit is spent, so nothing is left to fall back on.
    public var isExhausted: Bool { (usedPercentage ?? 0) >= 100 }

    /// Worth showing: turned on, or spent. Hitting the monthly spend limit
    /// turns `is_enabled` off (2.1.283), and that's when the spend matters most.
    /// An account that never turned credits on has nothing spent.
    public var isShown: Bool { isEnabled || isExhausted }

    /// "£12.50 of £50.00", or a percentage when there's no currency to format.
    public func amountLabel(locale: Locale = .current) -> String {
        guard let currency, let usedCredits else { return usedPercentage.map { "\(Int($0.rounded(.down)))% used" } ?? "" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        // Minor units per major unit follow the currency (2 digits for GBP, 0
        // for JPY). Set explicitly: Linux Foundation keeps 2 for every currency.
        let digits = UsageCredits.fractionDigits(currency)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let scale = pow(10, Double(digits))
        func format(_ minor: Double) -> String {
            formatter.string(from: NSNumber(value: minor / scale)) ?? "\(minor / scale) \(currency)"
        }
        guard let monthlyLimit else { return "\(format(usedCredits)) used" }
        return "\(format(usedCredits)) of \(format(monthlyLimit))"
    }

    /// ISO 4217 minor-unit digits; most currencies have 2.
    static func fractionDigits(_ currency: String) -> Int {
        switch currency.uppercased() {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF": return 0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND": return 3
        default: return 2
        }
    }
}

/// Plan usage from `claude -p /usage`.
public struct UsageSnapshot: Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var subscriptionType: String?
    public var updatedAt: Date
    /// Usage credits, from `/usage`'s report.
    public var credits: UsageCredits? = nil
    /// `claude /usage` said "You are currently using your overages". Only a
    /// positive signal: in `-p` mode it hasn't asked the API, so it can say
    /// "subscription" while credits are in use.
    public var reportsUsingCredits = false

    /// The snapshot as it stands at `now` (see `UsageWindow.current(at:)`),
    /// so the bars and credit badges follow a reset between readings.
    public func current(at now: Date) -> UsageSnapshot {
        var snapshot = self
        snapshot.fiveHour = fiveHour?.current(at: now)
        snapshot.sevenDay = sevenDay?.current(at: now)
        // The overage header described the state before the reset.
        if snapshot.fiveHour != fiveHour || snapshot.sevenDay != sevenDay { snapshot.reportsUsingCredits = false }
        return snapshot
    }

    /// No reading has arrived for several polls (signed out, the CLI failing),
    /// so the figures may be out of date.
    public func isStale(at now: Date, refreshInterval: TimeInterval) -> Bool {
        now.timeIntervalSince(updatedAt) > 3 * refreshInterval
    }

    /// A plan window is full, so Claude Code is either on credits or blocked.
    public var isAtPlanLimit: Bool {
        [fiveHour, sevenDay].contains { ($0?.usedPercentage ?? 0) >= 100 }
    }

    /// Claude Code is drawing on usage credits instead of the plan's limits.
    /// Worked out from the windows, because `/usage`'s overage header isn't
    /// reliable in `-p` mode.
    public var isUsingCredits: Bool {
        guard let credits, credits.isEnabled, !credits.isExhausted else { return false }
        return isAtPlanLimit || reportsUsingCredits
    }

    /// The credits being drawn on, when they are. The status bar then shows
    /// their spend instead of the plan windows, which don't move meanwhile.
    public var creditsInUse: UsageCredits? {
        isUsingCredits ? credits : nil
    }

    /// A plan limit is reached and the month's usage credits are spent too.
    /// Doesn't need `isEnabled`, which spending the limit turns off.
    public var isOutOfCredits: Bool {
        guard let credits, credits.isShown else { return false }
        return isAtPlanLimit && credits.isExhausted
    }

    /// When Claude Code can run again while a plan limit blocks it (out of
    /// credits, or credits never turned on): "back in 2h 14m", at the latest
    /// reset among the full windows (all of them block), or "until Sep 29 at
    /// 9am" when that's more than a day off. Nil while there's room or credits
    /// are being drawn on, or when no reset time is known. Topping up credits
    /// would also unblock it, but `/usage` doesn't say when they reset.
    public func blockedLabel(now: Date, timeZone: TimeZone = .current) -> String? {
        guard isAtPlanLimit, !isUsingCredits else { return nil }
        let full = [fiveHour, sevenDay].compactMap { $0 }.filter { $0.usedPercentage >= 100 }
        let resets = full.compactMap(\.resetsAt)
        if resets.count == full.count, let latest = resets.max() {
            let when = UsageWindow.when(latest, now: now, timeZone: timeZone, soon: "back in")
            return latest.timeIntervalSince(now) < 86400 ? when : "until \(when)"
        }
        // Only reset text that couldn't be read as a time, which can't be
        // compared with another window's. A time zone is dropped to keep it short.
        if full.count == 1, let text = full[0].resetText {
            let trimmed = text.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
            return "until \(trimmed)"
        }
        return nil
    }
}

extension UsageSnapshot {
    private static let usageLine = try! NSRegularExpression(pattern: #"^(Current session|Current week \(all models\)): (\d+(?:\.\d+)?)% used(?: · resets (.+))?$"#)

    /// Parses `claude -p /usage` output ("Current session: 56% used · resets 3pm").
    /// It needs no model call, so it works before any session has run.
    public static func parseUsageCommand(_ output: String, updatedAt: Date, timeZone: TimeZone = .current) -> UsageSnapshot? {
        var snapshot = UsageSnapshot(fiveHour: nil, sevenDay: nil, subscriptionType: nil, updatedAt: updatedAt)
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = usageLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let titleRange = Range(match.range(at: 1), in: line),
                  let percentRange = Range(match.range(at: 2), in: line),
                  let percent = Double(line[percentRange])
            else { continue }
            let reset = Range(match.range(at: 3), in: line).map { String(line[$0]) }
            // Read into a time, so it shows the way the stream's exact one does.
            let resetsAt = reset.flatMap { UsageWindow.parseResetText($0, now: updatedAt, timeZone: timeZone) }
            let window = UsageWindow(usedPercentage: percent, resetsAt: resetsAt, resetText: reset)
            if line[titleRange] == "Current session" { snapshot.fiveHour = window } else { snapshot.sevenDay = window }
        }
        snapshot.reportsUsingCredits = output.contains("currently using your overages")
        return snapshot.fiveHour == nil && snapshot.sevenDay == nil ? nil : snapshot
    }

    /// Parses `claude -p /usage --output-format stream-json --verbose`. Its
    /// `usage_report` has exact reset times and usage credits, which the text
    /// doesn't show. Falls back to the text when there's no report.
    public static func parseUsageStream(_ output: String, updatedAt: Date) -> UsageSnapshot? {
        var report: JSONValue?
        let text = usageText(fromStream: output)
        for line in output.split(separator: "\n") where line.hasPrefix("{") {
            if let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
               let value = event["usage_report"], value["rate_limits"] != nil {
                report = value
            }
        }
        guard let report else { return text.flatMap { parseUsageCommand($0, updatedAt: updatedAt) } }

        var snapshot = UsageSnapshot(fiveHour: nil, sevenDay: nil, subscriptionType: nil, updatedAt: updatedAt)
        let limits = report["rate_limits"]
        for limit in limits?["limits"]?.arrayValue ?? [] {
            guard let percent = limit["percent"]?.doubleValue else { continue }
            let window = UsageWindow(usedPercentage: percent, resetsAt: limit["resets_at"]?.stringValue.flatMap(parseResetDate))
            // The other kind, `weekly_scoped`, is one model's weekly limit
            // ("Current week (Sonnet)"). Reaching it blocks only that model,
            // so it doesn't count towards being on credits, and isn't shown.
            switch limit["kind"]?.stringValue {
            case "session": snapshot.fiveHour = window
            case "weekly_all": snapshot.sevenDay = window
            default: break
            }
        }
        // A missing or null `is_enabled` still leaves the spend worth reading.
        if let extra = limits?["extra_usage"], extra.objectValue != nil {
            snapshot.credits = UsageCredits(isEnabled: extra["is_enabled"]?.boolValue ?? false,
                                            monthlyLimit: extra["monthly_limit"]?.doubleValue,
                                            usedCredits: extra["used_credits"]?.doubleValue,
                                            utilization: extra["utilization"]?.doubleValue,
                                            currency: extra["currency"]?.stringValue)
        }
        snapshot.reportsUsingCredits = text?.contains("currently using your overages") == true
        if snapshot.fiveHour == nil && snapshot.sevenDay == nil {
            guard var fallback = text.flatMap({ parseUsageCommand($0, updatedAt: updatedAt) }) else { return nil }
            fallback.credits = snapshot.credits
            return fallback
        }
        return snapshot
    }

    /// The human-readable `/usage` text inside stream-json output: the result
    /// event's `result`, else the assistant message's text. Also what the
    /// Activity Log shows, since the report has account details (credit spend).
    public static func usageText(fromStream output: String) -> String? {
        var assistantText: String?
        for line in output.split(separator: "\n") where line.hasPrefix("{") {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            switch event["type"]?.stringValue {
            case "result":
                if let result = event["result"]?.stringValue, !result.isEmpty { return result }
            case "assistant":
                let parts = event["message"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
                if !parts.isEmpty { assistantText = parts.joined(separator: "\n") }
            default:
                break
            }
        }
        return assistantText
    }

    /// "2026-09-27T03:49:59.519416+00:00". Fractional seconds are dropped:
    /// Linux Foundation's ISO 8601 parsing doesn't take microseconds.
    static func parseResetDate(_ text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole)
    }
}

/// How full a session's context window is, from its status line input.
public struct ContextUsage: Equatable, Sendable {
    public var usedPercentage: Double
    public var windowSize: Int?
    public var inputTokens: Int?
    /// Worked out from the session's history rather than reported by Claude
    /// Code's status line, so the window size is a guess.
    public var isEstimate: Bool

    public init(usedPercentage: Double, windowSize: Int?, inputTokens: Int?, isEstimate: Bool = false) {
        self.usedPercentage = usedPercentage
        self.windowSize = windowSize
        self.inputTokens = inputTokens
        self.isEstimate = isEstimate
    }

    /// History records tokens but not the window size: assume the standard
    /// 200k window unless the model says 1M or usage has already passed 200k.
    public static func estimate(tokens: Int, model: String?) -> ContextUsage {
        let window = tokens > 200_000 || model?.lowercased().contains("[1m]") == true ? 1_000_000 : 200_000
        return ContextUsage(usedPercentage: Double(tokens) / Double(window) * 100, windowSize: window,
                            inputTokens: tokens, isEstimate: true)
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
    public var label: String { "\(isEstimate ? "~" : "")\(Int(usedPercentage.rounded()))%" }

    public var detail: String {
        let text: String
        if let windowSize {
            text = "\(inputTokens.map(ContextUsage.compact) ?? label) of \(ContextUsage.compact(windowSize)) tokens"
        } else {
            text = "\(label) of the context window used"
        }
        guard isEstimate else { return text }
        return text + ". Estimated from the session history, which doesn't record the window size, so this may be off. Sessions started or resumed in Claudio report it exactly."
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
/// Code's status line input (for the session's context window), then runs the
/// user's own status line command, if any, so their status line is unchanged.
/// Plan usage comes from `claude -p /usage` instead: each session's input
/// repeats the rate limits from its own last request, so idle ones are stale.
public struct StatusLineCapture: Equatable, Sendable {
    /// Where each session's latest status line input is kept, as
    /// `<directory>/<app session id>.json`.
    public var statusDirectory: String
    public var userStatusLine: UserStatusLine?

    public init(statusDirectory: String, userStatusLine: UserStatusLine?) {
        self.statusDirectory = statusDirectory
        self.userStatusLine = userStatusLine
    }

    public func command(for appSessionID: UUID) -> String {
        let directory = ShellQuote.quote(statusDirectory)
        let file = ShellQuote.quote((statusDirectory as NSString).appendingPathComponent("\(appSessionID.uuidString).json"))
        var command = #"input=$(cat); mkdir -p \#(directory) && printf '%s' "$input" > \#(file).$$ && mv -f \#(file).$$ \#(file); "#
        if let user = userStatusLine {
            command += #"printf '%s' "$input" | sh -c \#(ShellQuote.quote(user.command))"#
        } else {
            command += ":"
        }
        return command
    }

    func settingsValue(for appSessionID: UUID) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(command(for: appSessionID)),
        ]
        if let padding = userStatusLine?.padding { object["padding"] = .number(Double(padding)) }
        return .object(object)
    }
}

/// Watches plan usage for a limit that was reached and has now reset, so
/// Claudio can say you can work on your plan again.
public struct UsageResetTracker: Equatable, Sendable {
    public enum Window: String, Sendable, CaseIterable {
        case session, week
    }

    /// Windows seen at their limit that haven't reset since.
    private var atLimit: Set<Window> = []
    private var hasBaseline = false

    public init() {}

    /// Checks the latest reading as it stands at `now`, so a reset time that
    /// passes between readings counts at once (and a stale reading from
    /// Claude Code's cache, whose reset has passed, doesn't count as at the
    /// limit again). Returns the windows that were at their limit and no longer
    /// are. The first check with a reading only records where things stand.
    public mutating func check(_ snapshot: UsageSnapshot?, now: Date) -> [Window] {
        guard let snapshot = snapshot?.current(at: now) else { return [] }
        var reset: [Window] = []
        for window in Window.allCases {
            // A window missing from this reading tells us nothing.
            guard let usage = window == .session ? snapshot.fiveHour : snapshot.sevenDay else { continue }
            if usage.usedPercentage >= 100 {
                atLimit.insert(window)
            } else if atLimit.remove(window) != nil, hasBaseline {
                reset.append(window)
            }
        }
        hasBaseline = true
        return reset
    }
}
