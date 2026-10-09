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

/// A coloured label that can be put on sessions and folders (GitHub-style
/// issue labels). The catalog lives in `AppSettings.tags`; sessions and
/// folders hold ids into it, so renaming or recolouring a tag updates
/// everywhere it's used.
public struct Tag: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Six hex digits, no "#", always uppercase.
    public var colorHex: String

    public init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.colorHex = Tag.normalizedHex(colorHex) ?? Tag.palette[0]
    }

    /// A curated set of colours that read well against the app's dark
    /// theme; offered as swatches, with a custom hex field as an escape hatch.
    public static let palette = [
        "FF5C5C", "FF9F40", "FFD23F", "4CD787", "33C2C2",
        "4098FF", "7C83FF", "C77DFF", "FF6FB3", "9A9AA2",
    ]

    /// Normalizes "#abc", "abc", "#aabbcc" or "aabbcc" to six uppercase hex
    /// digits, or nil if it isn't a valid colour.
    public static func normalizedHex(_ input: String) -> String? {
        var hex = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3, hex.allSatisfy(\.isHexDigit) {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.uppercased()
    }

    /// Whether dark text reads better than white on this tag's colour
    /// (relative luminance, the same idea GitHub uses for label text).
    public var prefersDarkText: Bool {
        guard let (r, g, b) = Tag.rgb(ofHex: colorHex) else { return true }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6
    }

    /// Parses six hex digits (already normalized — no "#") into 0–1 RGB
    /// components, for any UI layer to turn into its own colour type.
    public static func rgb(ofHex hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

public extension Tag {
    // Fixed so a migrated session's tag id always matches its catalog
    // entry's id, and so tests comparing default catalogs aren't flaky.
    static let codeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let reviewID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let researchID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static let defaults: [Tag] = [
        Tag(id: codeID, name: "Code", colorHex: palette[5]),
        Tag(id: reviewID, name: "Review", colorHex: palette[1]),
        Tag(id: researchID, name: "Research", colorHex: palette[7]),
    ]
}

/// What a session is for: a free-form name, inferred from a tag list and
/// used while choosing a single tag. Empty is none.
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
    public var tags: [Tag.ID]
    /// Transient: holds an on-disk `role` string during decode of an older
    /// state file, until `PersistedState`'s v3 migration resolves it against
    /// the tag catalog and clears it. Never persisted (absent from
    /// `CodingKeys`), so it plays no part in equality once resolved.
    public var legacyRoleName: String?
    public var status: SessionStatus
    /// One-line description of where the session is at (card / tooltip text).
    public var summary: String
    /// What the user needs to do, when the session is awaiting input.
    public var needsAction: String?
    public var workingDirectory: String
    public var model: String?
    public var permissionMode: PermissionMode
    /// Pull requests the session opened or reviewed (see `PullRequestActivity`).
    public var pullRequests: [PullRequestLink]
    public var createdAt: Date
    public var lastActivity: Date
    public var isArchived: Bool
    /// Started with the Project Assistant's plugin and skills (`--plugin-dir`,
    /// `--add-dir`), so it can use approved skills and write notes. Flags are
    /// fixed at launch, so sessions started before the assistant never are.
    public var hasAssistant = false
    /// The skills its opening prompt named, when it was started from a plan item.
    public var namedSkills: [String] = []
    /// Its last turn ended with an API error (StopFailure), so it isn't
    /// followed up until a turn ends normally.
    public var lastTurnFailed = false
    /// Where its last follow-up got to in its history (see `FollowUpMark`).
    public var followUpMark: FollowUpMark?
    /// Where its history had got to when you chose Not Now on an offer: it's
    /// offered again only once the history has grown past it.
    public var followUpDeclined: FollowUpMark?
    /// Background tasks its last turn left running (from the Stop hook), so
    /// it stays Working until they finish. Checked again at launch
    /// (`BackgroundJobState`).
    public var backgroundTasks: [BackgroundTask] = []
    /// Tasks you marked finished while they still ran (a dev server, say):
    /// they don't keep it Working. Kept while Claude Code still reports them.
    public var finishedBackgroundTasks: [String] = []
    /// Conversations this session has moved on from (`/clear` starts a new
    /// one in the same process). Their history files stay behind, and are
    /// this session's, not new sessions to import.
    public var replacedConversations: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, projectID, claudeSessionID, agentID, hasConversation, name, hasCustomName, claudeTitle, lastBaseName, tags, status, summary, needsAction
        case workingDirectory, model, permissionMode, pullRequests, createdAt, lastActivity, isArchived, hasAssistant, namedSkills, lastTurnFailed, followUpMark, followUpDeclined
        case backgroundTasks, finishedBackgroundTasks, replacedConversations
    }

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        claudeSessionID: String? = nil,
        hasConversation: Bool = false,
        name: String,
        tags: [Tag.ID] = [],
        workingDirectory: String,
        status: SessionStatus = .completed,
        summary: String = "",
        model: String? = nil,
        permissionMode: PermissionMode = .standard,
        pullRequests: [PullRequestLink] = [],
        createdAt: Date = Date(),
        lastActivity: Date? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.claudeSessionID = claudeSessionID
        self.hasConversation = hasConversation
        self.name = name
        self.tags = tags
        self.workingDirectory = workingDirectory
        self.status = status
        self.summary = summary
        self.needsAction = nil
        self.agentID = nil
        self.hasCustomName = false
        self.model = model
        self.permissionMode = permissionMode
        self.pullRequests = pullRequests
        self.createdAt = createdAt
        self.lastActivity = lastActivity ?? createdAt
        self.isArchived = isArchived
    }
}

extension Session {
    /// Points the session at a conversation (from a hook or the agent list).
    /// One it had before is kept in `replacedConversations`.
    mutating func adoptConversation(_ id: String) {
        guard !id.isEmpty, id != claudeSessionID else { return }
        if let old = claudeSessionID, !replacedConversations.contains(old) { replacedConversations.append(old) }
        replacedConversations.removeAll { $0 == id }
        claudeSessionID = id
    }

    /// Every conversation that belongs to it: the current one and those
    /// `/clear` replaced.
    public var conversations: [String] {
        (claudeSessionID.map { [$0] } ?? []) + replacedConversations
    }
}

/// A user-named group of sessions within a project (e.g. a change and its PR review).
public struct Folder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Ordered session membership. A session is in at most one folder.
    public var sessionIDs: [UUID]
    public var isCollapsed: Bool
    /// Applied once to a session's own tags when it's created in this folder.
    public var defaultTags: [Tag.ID]

    public init(id: UUID = UUID(), name: String, sessionIDs: [UUID] = [], isCollapsed: Bool = false, defaultTags: [Tag.ID] = []) {
        self.id = id
        self.name = name
        self.sessionIDs = sessionIDs
        self.isCollapsed = isCollapsed
        self.defaultTags = defaultTags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  sessionIDs: try c.decodeIfPresent([UUID].self, forKey: .sessionIDs) ?? [],
                  isCollapsed: try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false,
                  defaultTags: try c.decodeIfPresent([UUID].self, forKey: .defaultTags) ?? [])
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
