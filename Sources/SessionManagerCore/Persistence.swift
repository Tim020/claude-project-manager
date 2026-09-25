import Foundation

/// How a folder's sessions are shown: one at a time with tabs (1a), or side by
/// side (1b).
public enum LayoutMode: String, Codable, CaseIterable, Sendable {
    case tabs
    case split
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Explicit path to the `claude` binary; located automatically when nil.
    public var claudePath: String?
    /// Model for new sessions; Claude Code's default when nil.
    public var defaultModel: String?
    public var defaultPermissionMode: PermissionMode
    public var layout: LayoutMode

    public init(claudePath: String? = nil, defaultModel: String? = nil, defaultPermissionMode: PermissionMode = .acceptEdits, layout: LayoutMode = .tabs) {
        self.claudePath = claudePath
        self.defaultModel = defaultModel
        self.defaultPermissionMode = defaultPermissionMode
        self.layout = layout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            claudePath: try c.decodeIfPresent(String.self, forKey: .claudePath),
            defaultModel: try c.decodeIfPresent(String.self, forKey: .defaultModel),
            defaultPermissionMode: try c.decodeIfPresent(PermissionMode.self, forKey: .defaultPermissionMode) ?? .acceptEdits,
            layout: try c.decodeIfPresent(LayoutMode.self, forKey: .layout) ?? .tabs)
    }
}

public struct PersistedState: Codable, Equatable, Sendable {
    public var version = 1
    public var workspace = Workspace()
    public var settings = AppSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        workspace = try c.decodeIfPresent(Workspace.self, forKey: .workspace) ?? Workspace()
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

public protocol StateStore {
    func load() throws -> PersistedState
    func save(_ state: PersistedState) throws
}

/// Stores app state as JSON, by default in
/// `~/Library/Application Support/SessionManager/state.json`.
public struct JSONFileStore: StateStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SessionManager/state.json")
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
            permissionMode: try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .acceptEdits,
            pullRequestURLs: try c.decodeIfPresent([String].self, forKey: .pullRequestURLs) ?? [],
            createdAt: createdAt,
            lastActivity: try c.decodeIfPresent(Date.self, forKey: .lastActivity) ?? createdAt,
            isArchived: try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false)
        self.needsAction = try c.decodeIfPresent(String.self, forKey: .needsAction)
    }
}
