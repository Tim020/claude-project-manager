import Foundation

/// A small icon shown beside a session (sidebar row), with its tooltip.
/// Only the "also open in a terminal" warning: a session's worktree and pull
/// requests are in the right rail's Pull Request tool (design 8c).
public struct SessionIndicator: Equatable, Sendable {
    public enum Kind: Sendable { case terminal }

    public var kind: Kind
    public var symbol: String
    public var help: String
}

public enum SessionIndicators {
    public static func indicators(for session: Session, isOpenInTerminal: Bool) -> [SessionIndicator] {
        guard isOpenInTerminal else { return [] }
        return [SessionIndicator(kind: .terminal, symbol: "terminal",
                                 help: "Also open in a terminal outside Claudio. Resuming it here starts a copy of the conversation.")]
    }

    /// Tooltip for a session's status dot.
    public static func statusHelp(_ session: Session) -> String {
        if session.status == .awaitingInput, let action = session.needsAction, !action.isEmpty {
            return "Awaiting Input: \(action)"
        }
        return session.status.label
    }
}
