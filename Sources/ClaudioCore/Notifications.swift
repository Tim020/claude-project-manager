import Foundation

/// Which session changes raise a macOS notification (Settings → Notifications).
public struct NotificationSettings: Codable, Equatable, Sendable {
    /// Claude asked for permission or asked a question.
    public var awaitingInput = true
    /// A session finished its turn.
    public var finished = true
    /// A background agent exited while it was working.
    public var stoppedUnexpectedly = false
    public var sound = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        awaitingInput = try c.decodeIfPresent(Bool.self, forKey: .awaitingInput) ?? true
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
        stoppedUnexpectedly = try c.decodeIfPresent(Bool.self, forKey: .stoppedUnexpectedly) ?? false
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
    }
}

public struct SessionNotification: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case awaitingInput, finished, stopped
    }

    public var sessionID: UUID
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var body: String

    public init(sessionID: UUID, kind: Kind, title: String, subtitle: String, body: String) {
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// Delivers notifications (macOS Notification Centre in the app; a fake in tests).
@MainActor
public protocol NotificationPosting: AnyObject {
    func post(_ notification: SessionNotification, sound: Bool)
}
