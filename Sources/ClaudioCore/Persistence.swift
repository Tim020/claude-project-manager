import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Explicit path to the `claude` binary; located automatically when nil.
    public var claudePath: String?
    /// Model for new sessions; Claude Code's default when nil.
    public var defaultModel: String?
    /// Permissions for new sessions run in a terminal (`claude` directly).
    public var defaultPermissionMode: PermissionMode
    /// Permissions for new background agents, which work unattended.
    public var defaultBackgroundPermissionMode = PermissionMode.auto
    /// Run new sessions as Claude Code background agents (`claude --bg`),
    /// attached in a terminal, instead of plain interactive processes.
    public var useBackgroundAgents: Bool
    /// Width of the resizable sidebar, in points.
    public var sidebarWidth: Double
    /// The roles offered for new sessions (editable in Settings).
    public var roles: [String]
    public var notifications = NotificationSettings()
    /// The sidebar only shows sessions active within this many days (plus
    /// ones working, awaiting input or open in a tab). 0 shows every session.
    public var activityWindowDays = AppSettings.defaultActivityWindowDays
    /// The tools open on the left and right rails (design 8c).
    public var toolWindows = ToolWindows()
    /// Height of the Shell panel under the panes, in points.
    public var shellPanelHeight = AppSettings.defaultShellPanelHeight
    /// Settings › Assistant: app-wide, because plan usage is the account's.
    public var assistant = AssistantAppSettings()
    public static let defaultActivityWindowDays = 14

    /// Quick choices for the window, in days (0 is any time).
    public static let activityWindowPresets = [1, 3, 7, 14, 30, 90, 0]

    /// "Any time", "Last day", "Last week", "Last 2 weeks", "Last 45 days"…
    public static func activityWindowLabel(days: Int) -> String {
        switch days {
        case ...0: return "Any time"
        case 1: return "Last day"
        case 7: return "Last week"
        case 14: return "Last 2 weeks"
        default: return "Last \(days) days"
        }
    }

    /// The cutoff for `activityWindowDays`, or nil for any time.
    public func activitySince(now: Date) -> Date? {
        activityWindowDays > 0 ? now.addingTimeInterval(-Double(activityWindowDays) * 86_400) : nil
    }

    /// The default for a new session: background agents have their own.
    public func defaultPermissionMode(background: Bool) -> PermissionMode {
        background ? defaultBackgroundPermissionMode : defaultPermissionMode
    }

    public static func cleanRoles(_ roles: [String]) -> [String] {
        var seen = Set<String>()
        return roles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public static let sidebarWidthRange: ClosedRange<Double> = 220...520

    public static func clampSidebarWidth(_ width: Double) -> Double {
        min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    public static let defaultShellPanelHeight: Double = 250
    public static let shellPanelHeightRange: ClosedRange<Double> = 120...900

    public static func clampShellPanelHeight(_ height: Double) -> Double {
        min(max(height, shellPanelHeightRange.lowerBound), shellPanelHeightRange.upperBound)
    }

    public init(claudePath: String? = nil, defaultModel: String? = nil, defaultPermissionMode: PermissionMode = .auto,
                useBackgroundAgents: Bool = true, sidebarWidth: Double = 290,
                roles: [String] = SessionRole.defaultNames) {
        self.claudePath = claudePath
        self.defaultModel = defaultModel
        self.defaultPermissionMode = defaultPermissionMode
        self.useBackgroundAgents = useBackgroundAgents
        self.sidebarWidth = AppSettings.clampSidebarWidth(sidebarWidth)
        self.roles = AppSettings.cleanRoles(roles)
    }

    private enum LegacyKeys: String, CodingKey {
        case showFilesInspector
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            claudePath: try c.decodeIfPresent(String.self, forKey: .claudePath),
            defaultModel: try c.decodeIfPresent(String.self, forKey: .defaultModel),
            defaultPermissionMode: try c.decodeIfPresent(PermissionMode.self, forKey: .defaultPermissionMode) ?? .auto,
            useBackgroundAgents: try c.decodeIfPresent(Bool.self, forKey: .useBackgroundAgents) ?? true,
            sidebarWidth: try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 290,
            roles: try c.decodeIfPresent([String].self, forKey: .roles) ?? SessionRole.defaultNames)
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        defaultBackgroundPermissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .defaultBackgroundPermissionMode) ?? .auto
        if let tools = try c.decodeIfPresent(ToolWindows.self, forKey: .toolWindows) {
            toolWindows = tools
        } else {
            // Before the rails, Files Changed was an inspector beside the
            // terminal; it's the right rail's Changes tool now.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            toolWindows.isRightOpen = try legacy.decodeIfPresent(Bool.self, forKey: .showFilesInspector) ?? false
        }
        shellPanelHeight = AppSettings.clampShellPanelHeight(
            try c.decodeIfPresent(Double.self, forKey: .shellPanelHeight) ?? AppSettings.defaultShellPanelHeight)
        activityWindowDays = max(0, try c.decodeIfPresent(Int.self, forKey: .activityWindowDays) ?? AppSettings.defaultActivityWindowDays)
        assistant = (try? c.decodeIfPresent(AssistantAppSettings.self, forKey: .assistant)) ?? AssistantAppSettings()
    }
}

/// Settings › Assistant (design 9a).
public struct AssistantAppSettings: Codable, Equatable, Sendable {
    /// "Use the assistant". Off turns it off in every project; notes and
    /// plans stay, and Promote… makes an Idea without calling Claude.
    public var isEnabled = true
    /// Background work pauses when the 5-hour or weekly window reaches this
    /// percentage. Things you start yourself always run. Kept in range here,
    /// not only by the Settings control.
    public var pauseThreshold = AssistantAppSettings.defaultPauseThreshold {
        didSet { pauseThreshold = AssistantAppSettings.clamp(pauseThreshold, to: AssistantAppSettings.pauseThresholdRange) }
    }
    /// Whether background work may run while usage credits are being spent.
    public var allowWhileUsingCredits = false
    /// Background calls a day for sign-ins without a plan-usage reading
    /// (API key, Bedrock, Vertex), where the usage threshold can't apply.
    public var dailyJobLimit = AssistantAppSettings.defaultDailyJobLimit {
        didSet { dailyJobLimit = AssistantAppSettings.clamp(dailyJobLimit, to: AssistantAppSettings.dailyJobLimitRange) }
    }

    public static let defaultPauseThreshold = 80
    public static let pauseThresholdRange = 50...100
    public static let defaultDailyJobLimit = 20
    public static let dailyJobLimitRange = 1...200

    public init() {}

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Each field on its own: one that can't be read takes its default
    /// without resetting the others (so the switch stays off if it was).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The switch fails closed: a value that's there but can't be read
        // keeps the assistant off. Only a missing one means on.
        if c.contains(.isEnabled) {
            isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false
        }
        let threshold = ((try? c.decodeIfPresent(Int.self, forKey: .pauseThreshold)) ?? nil) ?? AssistantAppSettings.defaultPauseThreshold
        pauseThreshold = AssistantAppSettings.clamp(threshold, to: AssistantAppSettings.pauseThresholdRange)
        allowWhileUsingCredits = ((try? c.decodeIfPresent(Bool.self, forKey: .allowWhileUsingCredits)) ?? nil) ?? false
        let limit = ((try? c.decodeIfPresent(Int.self, forKey: .dailyJobLimit)) ?? nil) ?? AssistantAppSettings.defaultDailyJobLimit
        dailyJobLimit = AssistantAppSettings.clamp(limit, to: AssistantAppSettings.dailyJobLimitRange)
    }
}

public struct PersistedState: Codable, Equatable, Sendable {
    /// 2: the default permission mode for new sessions became Auto.
    public static let currentVersion = 2
    public var version = PersistedState.currentVersion
    public var workspace = Workspace()
    public var settings = AppSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        workspace = try c.decodeIfPresent(Workspace.self, forKey: .workspace) ?? Workspace()
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        if version < 2 && settings.defaultPermissionMode == .standard {
            // "Ask" was the old default rather than a choice; Claude agents default to Auto.
            settings.defaultPermissionMode = .auto
        }
        version = PersistedState.currentVersion
    }
}

public protocol StateStore {
    func load() throws -> PersistedState
    func save(_ state: PersistedState) throws
}

/// Stores app state as JSON, by default in
/// `~/Library/Application Support/Claudio/state.json`.
public struct JSONFileStore: StateStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Claudio/state.json")
    }

    /// The app used to be called Session Manager: carry its data folder
    /// (state, hook log, usage) over to the new name once.
    @discardableResult
    public static func migrateLegacyDirectory(from legacy: URL, to current: URL) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) else { return false }
        try? fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? fileManager.moveItem(at: legacy, to: current)) != nil
    }

    public static var legacyDirectoryURL: URL {
        defaultURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SessionManager")
    }

    public func load() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return PersistedState() }
        return try JSONFileStore.decoder.decode(PersistedState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONFileStore.encoder.encode(state).write(to: url, options: .atomic)
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter().string(from: date))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = fractionalFormatter().date(from: string) ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
        }
        return decoder
    }

    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

extension Session {
    /// Tolerant decoding so state files written by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            projectID: try c.decode(UUID.self, forKey: .projectID),
            claudeSessionID: try c.decodeIfPresent(String.self, forKey: .claudeSessionID),
            hasConversation: try c.decodeIfPresent(Bool.self, forKey: .hasConversation) ?? false,
            name: name,
            role: try c.decodeIfPresent(SessionRole.self, forKey: .role),
            workingDirectory: try c.decode(String.self, forKey: .workingDirectory),
            status: try c.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .completed,
            summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
            model: try c.decodeIfPresent(String.self, forKey: .model),
            permissionMode: try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .standard,
            // Earlier versions kept every pull request link a session saw
            // (`pullRequestURLs`); those aren't carried over, and history
            // discovery finds the ones it acted on again.
            // Tolerant: they can be found again, so a newer build's values
            // mustn't fail the whole state.
            pullRequests: ((try? c.decodeIfPresent([PullRequestLink].self, forKey: .pullRequests)) ?? nil) ?? [],
            createdAt: createdAt,
            lastActivity: try c.decodeIfPresent(Date.self, forKey: .lastActivity) ?? createdAt,
            isArchived: try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false)
        self.needsAction = try c.decodeIfPresent(String.self, forKey: .needsAction)
        self.agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        self.hasCustomName = try c.decodeIfPresent(Bool.self, forKey: .hasCustomName) ?? false
        self.claudeTitle = try c.decodeIfPresent(String.self, forKey: .claudeTitle)
        self.lastBaseName = try c.decodeIfPresent(String.self, forKey: .lastBaseName)
        self.hasAssistant = try c.decodeIfPresent(Bool.self, forKey: .hasAssistant) ?? false
        self.namedSkills = (try? c.decodeIfPresent([String].self, forKey: .namedSkills)) ?? []
        self.lastTurnFailed = try c.decodeIfPresent(Bool.self, forKey: .lastTurnFailed) ?? false
        // Tolerant: a mark that can't be read is set again from the history.
        self.followUpMark = (try? c.decodeIfPresent(FollowUpMark.self, forKey: .followUpMark)) ?? nil
        self.followUpDeclined = (try? c.decodeIfPresent(FollowUpMark.self, forKey: .followUpDeclined)) ?? nil
    }
}
