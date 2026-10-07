import Foundation

// Usage (design 11a): the ranges, and the figures each view shows. Costs are
// in USD, at API rates: an estimate ("est.") on a plan.

/// The Usage tool's range (kept per project).
public enum UsageRange: Hashable, Codable, Sendable {
    case day, week, month, all
    /// Whole days, from the start of `from` to the end of `to`.
    case custom(from: Date, to: Date)

    public static let presets: [UsageRange] = [.day, .week, .month, .all]

    public var shortLabel: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

/// How long each bar covers.
public enum UsageStep: Equatable, Sendable {
    case hour, day, week
}

/// A range made concrete: when it starts and ends, its bars, and its words.
public struct UsagePeriod: Equatable, Sendable {
    /// Nil for All with nothing recorded yet.
    public var start: Date?
    public var end: Date
    public var step: UsageStep
    /// "Last 7 days", "All time, since 4 Aug", "22 Sep – 28 Sep 2026".
    public var label: String
    /// Where each bar starts, oldest first.
    public var bars: [Date]

    public func contains(_ date: Date) -> Bool {
        guard let start else { return false }
        return date >= start && date < end
    }
}

public enum UsageDates {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Gregorian, Monday first, in the zone given (the user's, or a test's).
    public static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    /// "22 Sep", or "22 Sep 2026" with the year. Built by hand so it reads
    /// the same in every locale, and on Linux.
    public static func day(_ date: Date, calendar: Calendar, year: Bool = false) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let text = "\(parts.day ?? 1) \(months[(parts.month ?? 1) - 1])"
        return year ? "\(text) \(parts.year ?? 1970)" : text
    }

    /// "14:00".
    public static func hour(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d:00", calendar.component(.hour, from: date))
    }

    /// "22 Sep – 28 Sep 2026", or "22 Dec 2025 – 3 Jan 2026" across years.
    public static func span(_ from: Date, _ to: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: from) == calendar.component(.year, from: to)
        return "\(day(from, calendar: calendar, year: !sameYear)) – \(day(to, calendar: calendar, year: true))"
    }
}

extension UsageRange {
    /// The range as it stands at `now`. `earliest` is the first usage
    /// recorded, where All starts.
    public func period(now: Date, earliest: Date?, calendar: Calendar) -> UsagePeriod {
        let today = calendar.startOfDay(for: now)
        func days(from start: Date, through last: Date) -> [Date] {
            var bars: [Date] = []
            var day = start
            while day <= last {
                bars.append(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return bars
        }
        switch self {
        case .day:
            let thisHour = Date(timeIntervalSince1970: TimeInterval(UsageBucket.hour(of: now)) * 3600)
            let bars = (0..<24).reversed().map { thisHour.addingTimeInterval(-3600 * TimeInterval($0)) }
            return UsagePeriod(start: bars[0], end: thisHour.addingTimeInterval(3600), step: .hour, label: "Last 24 hours", bars: bars)
        case .week, .month:
            let count = self == .week ? 7 : 30
            let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            return UsagePeriod(start: start, end: end, step: .day, label: "Last \(count) days", bars: days(from: start, through: today))
        case .custom(let from, let to):
            let first = calendar.startOfDay(for: min(from, to))
            let last = calendar.startOfDay(for: max(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            return UsagePeriod(start: first, end: end, step: .day, label: UsageDates.span(first, last, calendar: calendar),
                               bars: days(from: first, through: last))
        case .all:
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            guard let earliest else {
                return UsagePeriod(start: nil, end: end, step: .week, label: "All time", bars: [])
            }
            let first = calendar.dateInterval(of: .weekOfYear, for: earliest)?.start ?? calendar.startOfDay(for: earliest)
            var bars: [Date] = []
            var week = first
            while week < end {
                bars.append(week)
                guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { break }
                week = next
            }
            let sameYear = calendar.component(.year, from: earliest) == calendar.component(.year, from: now)
            return UsagePeriod(start: first, end: end, step: .week,
                               label: "All time, since \(UsageDates.day(earliest, calendar: calendar, year: !sameYear))", bars: bars)
        }
    }
}

extension UsagePeriod {
    /// The bar a moment falls in, if any.
    func barIndex(of date: Date) -> Int? {
        guard contains(date), !bars.isEmpty else { return nil }
        var low = 0, high = bars.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if bars[middle] <= date { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// A bar's label: "14:00" by the hour, "22 Sep" by the day or week.
    public func label(ofBar index: Int, calendar: Calendar) -> String {
        guard bars.indices.contains(index) else { return "" }
        return step == .hour ? UsageDates.hour(bars[index], calendar: calendar) : UsageDates.day(bars[index], calendar: calendar)
    }
}

/// One hour of a conversation's use, or one assistant call, priced.
public struct UsageEntry: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case session(conversationID: String)
        /// An assistant call: its job ("Follow-up") and model ("Sonnet").
        case assistant(job: String, model: String)
    }

    public var source: Source
    public var projectID: UUID
    /// The session (for an assistant call, the session it was about).
    public var sessionID: UUID?
    public var date: Date
    public var cost: Double
    /// Unknown for assistant calls (Claude Code reports only the cost).
    public var tokens: TokenCounts
    /// The model id, or for an assistant call its name ("Sonnet").
    public var model: String
    public var family: ModelFamily?
    /// Priced at its family's rate, its own model not being in the table.
    public var isFallbackPriced: Bool

    public init(source: Source, projectID: UUID, sessionID: UUID?, date: Date, cost: Double, tokens: TokenCounts = TokenCounts(),
                model: String, family: ModelFamily?, isFallbackPriced: Bool = false) {
        self.source = source
        self.projectID = projectID
        self.sessionID = sessionID
        self.date = date
        self.cost = cost
        self.tokens = tokens
        self.model = model
        self.family = family
        self.isFallbackPriced = isFallbackPriced
    }

    public var isAssistant: Bool {
        if case .assistant = source { return true }
        return false
    }

    public var conversationID: String? {
        if case .session(let id) = source { return id }
        return nil
    }
}

/// What a bar segment, row or legend entry is coloured as. The UI turns
/// these into colours: a series colour (teal, amber, purple…) at a shade
/// (opacity 1, .62, .4, .25), or the assistant's blue.
public enum UsageColor: Hashable, Sendable {
    case series(Int, shade: Int)
    case assistant
}

public struct UsageSegment: Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: UsageColor
    public var cost: Double
}

public struct UsageBar: Equatable, Sendable, Identifiable {
    public var start: Date
    public var label: String
    /// Bottom to top; the assistant's is last.
    public var segments: [UsageSegment]

    public var id: Date { start }
    public var cost: Double { segments.reduce(0) { $0 + $1.cost } }
}

public struct ModelShare: Equatable, Sendable, Identifiable {
    public var family: ModelFamily
    public var cost: Double
    public var id: ModelFamily { family }
}

/// A row in the Usage tool's list.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case folder(SessionGroup)
        case session(UUID)
        /// A removed or deleted session: counted, shown muted, not clickable.
        case removed
        case project(UUID)
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var color: UsageColor
    public var cost: Double
    public var tokens: Int
    /// Its part of the scope's cost (0…1).
    public var share: Double

    public var isRemoved: Bool { kind == .removed }
}

public enum UsageScope: Hashable, Sendable {
    case project(UUID)
    case group(SessionGroup)
    /// Every project (the Usage window).
    case all
}

public struct UsageReport: Equatable, Sendable {
    public var period: UsagePeriod
    /// "CLAUDE-PROJECT-MANAGER", "ALL PROJECTS".
    public var title: String
    /// Session tokens (assistant calls report only a cost).
    public var tokens: Int
    /// This scope's part of all usage in the range (nil for all of it).
    public var shareOfAll: Double?
    public var sessionsCost: Double
    public var assistantCost: Double
    public var bars: [UsageBar]
    public var byModel: [ModelShare]
    /// Folders (a project), sessions (a folder) or projects (all).
    public var rows: [UsageRow]
    /// Families some messages were priced at, their own model not being
    /// in the table.
    public var fallbackFamilies: [ModelFamily]

    public var cost: Double { sessionsCost + assistantCost }
    public var isEmpty: Bool { cost <= 0 && tokens == 0 }
}

/// A session's all-time usage (right rail › Usage).
public struct SessionUsage: Equatable, Sendable {
    public var cost: Double
    public var tokens: TokenCounts
    public var byModel: [ModelShare]
    /// Its part of this week's limit; nil without a weekly reading.
    public var week: WeekShare?
    public var turns: Int
    /// The model it spent most on ("Opus 5.5").
    public var mainModel: String?
    /// What the assistant's follow-ups on it cost; nil for none.
    public var followUpCost: Double?
    public var fallbackFamilies: [ModelFamily]
}

/// A session's part of this week's limit, worked out from its share of the
/// last 7 days' usage.
public struct WeekShare: Equatable, Sendable {
    /// Its part of the limit (0…1).
    public var share: Double
    /// The week's used percentage it's a share of.
    public var used: Double
}

/// The assistant's own figures (the Usage window).
public struct AssistantUsage: Equatable, Sendable {
    public struct Job: Equatable, Sendable, Identifiable {
        public var name: String
        public var model: String
        public var calls: Int
        public var cost: Double
        public var id: String { "\(name)|\(model)" }
    }

    public struct Project: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var cost: Double
    }

    public var cost: Double
    public var calls: Int
    public var shareOfAll: Double
    public var jobs: [Job]
    public var projects: [Project]
}

/// A row of the Usage window's project table.
public struct ProjectUsageRow: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: UsageColor
    public var sessionsCost: Double
    /// Nil when the assistant is off in the project.
    public var assistantCost: Double?
    public var cost: Double
    public var share: Double
}

public enum UsageFormat {
    /// "$12.40", "$0.42", "$1,204": cents below $1,000.
    public static func cost(_ value: Double) -> String {
        if value >= 1000 {
            let whole = Int(value.rounded())
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_GB")
            return "$" + (formatter.string(from: NSNumber(value: whole)) ?? "\(whole)")
        }
        return String(format: "$%.2f", value)
    }

    /// "812", "48.2K", "1.4M", "2.1B".
    public static func tokens(_ value: Int) -> String {
        let number = Double(value)
        func short(_ divided: Double, _ unit: String) -> String {
            let text = divided >= 100 ? String(format: "%.0f", divided) : String(format: "%.1f", divided)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        switch number {
        case ..<1000: return "\(value)"
        case ..<1_000_000: return short(number / 1000, "K")
        case ..<1_000_000_000: return short(number / 1_000_000, "M")
        default: return short(number / 1_000_000_000, "B")
        }
    }

    /// "31%", or "<1%" for a little.
    public static func percent(_ fraction: Double) -> String {
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// "Some messages priced at Sonnet rates." for the footnote.
    public static func fallbackNote(_ families: [ModelFamily]) -> String? {
        guard !families.isEmpty else { return nil }
        let names = families.map(\.name)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Some messages priced at \(list) rates."
    }
}
