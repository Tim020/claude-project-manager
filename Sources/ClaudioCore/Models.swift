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

/// What a session is for. Shown as a small uppercase tag (CODE, REVIEW, …).
public enum SessionRole: String, Codable, CaseIterable, Sendable {
    case code
    case review
    case research
    case other

    public var label: String { rawValue.uppercased() }

    /// A best guess from the session name, used as the default in the New Session sheet
    /// and for imported sessions.
    public static func infer(fromName name: String) -> SessionRole {
        let lower = name.lowercased()
        if lower.contains("review") { return .review }
        if ["research", "spike", "explore", "options paper", "pdf script handling"].contains(where: lower.contains) {
            return .research
        }
        return .code
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
        case id, projectID, claudeSessionID, agentID, hasConversation, name, hasCustomName, role, status, summary, needsAction
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
