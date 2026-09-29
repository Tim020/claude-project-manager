import Foundation

/// Which session changes raise a macOS notification (Settings → Notifications).
public struct NotificationSettings: Codable, Equatable, Sendable {
    /// Claude asked for permission or asked a question.
    public var awaitingInput = true
    /// A session finished its turn.
    public var finished = true
    /// A background agent exited while it was working.
    public var stoppedUnexpectedly = false
    /// A plan limit (session or weekly) that was reached has reset.
    public var usageReset = true
    public var sound = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        awaitingInput = try c.decodeIfPresent(Bool.self, forKey: .awaitingInput) ?? true
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
        stoppedUnexpectedly = try c.decodeIfPresent(Bool.self, forKey: .stoppedUnexpectedly) ?? false
        usageReset = try c.decodeIfPresent(Bool.self, forKey: .usageReset) ?? true
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
    }
}

public struct SessionNotification: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case awaitingInput, finished, stopped, usageReset
    }

    /// The session it's about; nil for app-wide ones (a usage reset).
    public var sessionID: UUID?
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var body: String
    /// Notification Centre's id: a newer notification with the same one
    /// replaces the last (one per session, one per usage window).
    public var identifier: String
    /// Notification Centre's group. Notifications in a group stack together and
    /// can be cleared at once, so it's shared (all sessions, all usage resets),
    /// not per session like `identifier`.
    public var threadIdentifier: String

    public static let sessionsThread = "sessions"
    public static let usageThread = "usage"

    public init(sessionID: UUID, kind: Kind, title: String, subtitle: String, body: String) {
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        identifier = sessionID.uuidString
        threadIdentifier = Self.sessionsThread
    }

    /// A plan limit that was reached has reset.
    public init(usageReset window: UsageResetTracker.Window) {
        sessionID = nil
        kind = .usageReset
        switch window {
        case .session:
            title = "Session limit reset"
            body = "Your 5-hour usage limit has reset, so sessions run on your plan again."
        case .week:
            title = "Weekly limit reset"
            body = "Your weekly usage limit has reset, so sessions run on your plan again."
        }
        subtitle = ""
        identifier = "usage-reset-\(window.rawValue)"
        threadIdentifier = Self.usageThread
    }
}

/// Delivers notifications (macOS Notification Centre in the app; a fake in tests).
@MainActor
public protocol NotificationPosting: AnyObject {
    func post(_ notification: SessionNotification, sound: Bool)
}
