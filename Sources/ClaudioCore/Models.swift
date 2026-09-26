import Foundation

/// The three states a session can be in, as shown throughout the design
/// (colour + word): Working, Awaiting Input, Completed.
public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case working
    case awaitingInput
    case completed

    public var label: String {
        switch self {
        case .working: return "Working"
        case .awaitingInput: return "Awaiting Input"
        case .completed: return "Completed"
        }
    }
}

/// What a session is for: a free-form label from the user's role list
/// (Settings), shown as a small uppercase tag (CODE, REVIEW, …). Empty is none.
public struct SessionRole: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ name: String) { self.init(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines)) }

    public static let code = SessionRole("Code")
    public static let review = SessionRole("Review")
    public static let research = SessionRole("Research")
    public static let none = SessionRole("")
    public static let defaultNames = ["Code", "Review", "Research"]

    public var label: String { rawValue.uppercased() }
    public var isNone: Bool { rawValue.isEmpty }

    /// The first role whose name appears in the session name; otherwise Code
    /// if that's in the list, or no role.
    public static func infer(fromName name: String, roles: [String] = defaultNames) -> SessionRole {
        let lower = name.lowercased()
        if let match = roles.first(where: { !$0.isEmpty && lower.contains($0.lowercased()) }) { return SessionRole(match) }
        if roles.contains(where: { $0.caseInsensitiveCompare("Research") == .orderedSame }),
           ["spike", "explore", "options paper", "investigate options"].contains(where: lower.contains) {
            return .research
        }
        return roles.contains(where: { $0.caseInsensitiveCompare("Code") == .orderedSame }) ? .code : .none
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Earlier versions stored a fixed set of lowercase values.
        switch raw {
        case "code": self = .code
        case "review": self = .review
        case "research": self = .research
        case "other": self = .none
        default: self.init(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Claude Code `--permission-mode` values. `.standard` passes no flag, so
/// Claude Code asks for permission as usual (in the session's terminal).
public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case standard = "default"
    case acceptEdits
    case auto
    case plan
    case dontAsk
    case bypassPermissions

    public var label: String {
        switch self {
        case .standard: return "Ask (default)"
        case .acceptEdits: return "Accept Edits"
        case .auto: return "Auto"
        case .plan: return "Plan Only"
        case .dontAsk: return "Don't Ask"
        case .bypassPermissions: return "Bypass Permissions"
        }
    }
}

/// A single Claude Code conversation.
public struct Session: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var projectID: UUID
    /// The Claude Code session UUID (the `.jsonl` file name under `~/.claude/projects`).
    public var claudeSessionID: String?
    /// Short id of the Claude Code background agent running this session
    /// (`claude attach/stop/rm <id>`), when it was started with `--bg`.
    public var agentID: String?
    /// Whether Claude Code has a transcript for this session, i.e. it must be
    /// launched with `--resume` rather than `--session-id`.
    public var hasConversation: Bool
    public var name: String
    /// The user chose this name, so Claude Code's own title doesn't replace it.
    public var hasCustomName: Bool
    /// The last title Claude Code had for this session (its `custom-title`,
    /// set by `/rename` or by Claudio), to spot renames made in the terminal.
    public var claudeTitle: String?
    /// The branch Files Changed last compared this session against ("dev"),
    /// so "vs" is right before the next comparison finishes.
    public var lastBaseName: String?
    public var role: SessionRole
    public var status: SessionStatus
    /// One-line description of where the session is at (card / tooltip text).
    public var summary: String
    /// What the user needs to do, when the session is awaiting input.
    public var needsAction: String?
    public var workingDirectory: String
    public var model: String?
    public var permissionMode: PermissionMode
    public var pullRequestURLs: [String]
    public var createdAt: Date
    public var lastActivity: Date
    public var isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, projectID, claudeSessionID, agentID, hasConversation, name, hasCustomName, claudeTitle, lastBaseName, role, status, summary, needsAction
        case workingDirectory, model, permissionMode, pullRequestURLs, createdAt, lastActivity, isArchived
    }

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        claudeSessionID: String? = nil,
        hasConversation: Bool = false,
        name: String,
        role: SessionRole? = nil,
        workingDirectory: String,
        status: SessionStatus = .completed,
        summary: String = "",
        model: String? = nil,
        permissionMode: PermissionMode = .standard,
        pullRequestURLs: [String] = [],
        createdAt: Date = Date(),
        lastActivity: Date? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.claudeSessionID = claudeSessionID
        self.hasConversation = hasConversation
        self.name = name
        self.role = role ?? SessionRole.infer(fromName: name)
        self.workingDirectory = workingDirectory
        self.status = status
        self.summary = summary
        self.needsAction = nil
        self.agentID = nil
        self.hasCustomName = false
        self.model = model
        self.permissionMode = permissionMode
        self.pullRequestURLs = pullRequestURLs
        self.createdAt = createdAt
        self.lastActivity = lastActivity ?? createdAt
        self.isArchived = isArchived
    }
}

/// A user-named group of sessions within a project (e.g. a change and its PR review).
public struct Folder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Ordered session membership. A session is in at most one folder.
    public var sessionIDs: [UUID]
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, sessionIDs: [UUID] = [], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.sessionIDs = sessionIDs
        self.isCollapsed = isCollapsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  sessionIDs: try c.decodeIfPresent([UUID].self, forKey: .sessionIDs) ?? [],
                  isCollapsed: try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false)
    }
}

/// A working directory that Claude Code sessions run in.
public struct Project: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var folders: [Folder]
    public var isCollapsed: Bool
    /// Whether the project's Unfiled group is collapsed in the sidebar.
    public var isUnfiledCollapsed: Bool
    /// The branch "vs main" compares against when a session has no pull
    /// request to say; nil for the repository's default branch.
    public var comparisonBranch: String?

    public init(id: UUID = UUID(), name: String, path: String, folders: [Folder] = [], isCollapsed: Bool = false,
                isUnfiledCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.folders = folders
        self.isCollapsed = isCollapsed
        self.isUnfiledCollapsed = isUnfiledCollapsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  path: try c.decode(String.self, forKey: .path),
                  folders: try c.decodeIfPresent([Folder].self, forKey: .folders) ?? [],
                  isCollapsed: try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false,
                  isUnfiledCollapsed: try c.decodeIfPresent(Bool.self, forKey: .isUnfiledCollapsed) ?? false)
        comparisonBranch = try c.decodeIfPresent(String.self, forKey: .comparisonBranch)
    }
}

/// Where a session lives: in a folder, or in its project's Unfiled group.
public enum SessionGroup: Hashable, Codable, Sendable {
    case folder(UUID)
    case unfiled(projectID: UUID)
}

public struct StatusCounts: Equatable, Sendable {
    public var working: Int
    public var awaitingInput: Int
    public var completed: Int

    public init(working: Int = 0, awaitingInput: Int = 0, completed: Int = 0) {
        self.working = working
        self.awaitingInput = awaitingInput
        self.completed = completed
    }

    /// Counts the sessions' states.
    public init(_ sessions: [Session]) {
        self.init()
        for session in sessions {
            switch session.status {
            case .working: working += 1
            case .awaitingInput: awaitingInput += 1
            case .completed: completed += 1
            }
        }
    }

    public var total: Int { working + awaitingInput + completed }

    public static func + (a: StatusCounts, b: StatusCounts) -> StatusCounts {
        StatusCounts(working: a.working + b.working, awaitingInput: a.awaitingInput + b.awaitingInput,
                     completed: a.completed + b.completed)
    }

    public subscript(status: SessionStatus) -> Int {
        switch status {
        case .working: return working
        case .awaitingInput: return awaitingInput
        case .completed: return completed
        }
    }
}

public enum WorkspaceError: Error, Equatable {
    case projectNotFound
    case folderNotFound
    case sessionNotFound
    case folderNotInProject
    case emptyName
}
