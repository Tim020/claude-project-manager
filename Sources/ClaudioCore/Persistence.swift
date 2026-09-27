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
    /// The Files Changed inspector beside the terminal is open.
    public var showFilesInspector = false
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
        showFilesInspector = try c.decodeIfPresent(Bool.self, forKey: .showFilesInspector) ?? false
        activityWindowDays = max(0, try c.decodeIfPresent(Int.self, forKey: .activityWindowDays) ?? AppSettings.defaultActivityWindowDays)
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
            pullRequestURLs: try c.decodeIfPresent([String].self, forKey: .pullRequestURLs) ?? [],
            createdAt: createdAt,
            lastActivity: try c.decodeIfPresent(Date.self, forKey: .lastActivity) ?? createdAt,
            isArchived: try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false)
        self.needsAction = try c.decodeIfPresent(String.self, forKey: .needsAction)
        self.agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        self.hasCustomName = try c.decodeIfPresent(Bool.self, forKey: .hasCustomName) ?? false
        self.claudeTitle = try c.decodeIfPresent(String.self, forKey: .claudeTitle)
        self.lastBaseName = try c.decodeIfPresent(String.self, forKey: .lastBaseName)
    }
}
