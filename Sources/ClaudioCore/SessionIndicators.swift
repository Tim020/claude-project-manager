import Foundation

/// A small icon shown beside a session (sidebar row), with its tooltip.
public struct SessionIndicator: Equatable, Sendable {
    public enum Kind: Sendable { case terminal, worktree, pullRequests }

    public var kind: Kind
    public var symbol: String
    /// Short text beside the icon (e.g. the PR count), if any.
    public var text: String?
    public var help: String
}

public enum SessionIndicators {
    public static func indicators(for session: Session, isOpenInTerminal: Bool) -> [SessionIndicator] {
        var result: [SessionIndicator] = []
        if isOpenInTerminal {
            result.append(SessionIndicator(kind: .terminal, symbol: "terminal", text: nil,
                                           help: "Also open in a terminal outside Claudio. Resuming it here starts a copy of the conversation."))
        }
        if let worktree = Worktree.name(ofPath: session.workingDirectory) {
            result.append(SessionIndicator(kind: .worktree, symbol: "arrow.triangle.branch", text: nil,
                                           help: "Runs in its own git worktree, “\(worktree)” (.claude/worktrees/\(worktree)), so its changes stay apart from your main checkout."))
        }
        let prs = session.pullRequestURLs
        if !prs.isEmpty {
            result.append(SessionIndicator(kind: .pullRequests, symbol: "arrow.triangle.pull",
                                           text: prs.count > 1 ? "\(prs.count)" : nil, help: pullRequestHelp(prs)))
        }
        return result
    }

    /// "1 pull request: #1427", "2 pull requests: #1427, #1430".
    public static func pullRequestHelp(_ urls: [String]) -> String {
        let numbers = urls.map { url in
            let last = (url as NSString).lastPathComponent
            return Int(last) != nil ? "#\(last)" : url
        }
        let noun = urls.count == 1 ? "pull request" : "pull requests"
        return "\(urls.count) \(noun): \(numbers.joined(separator: ", "))"
    }

    /// Tooltip for a session's status dot.
    public static func statusHelp(_ session: Session) -> String {
        if session.status == .awaitingInput, let action = session.needsAction, !action.isEmpty {
            return "Awaiting Input: \(action)"
        }
        return session.status.label
    }
}
