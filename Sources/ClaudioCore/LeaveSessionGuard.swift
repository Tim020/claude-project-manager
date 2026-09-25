import Foundation

/// Keeps ← from taking a terminal out of its session.
///
/// Claude Code's TUI leaves a session for its agents view when you press ←
/// twice on an empty prompt: the first press shows "Press ← again to go back
/// to agents" (or "…to open agents" / "Ambiguous ←, press again to detach"),
/// and a second press within a few seconds leaves. The app has its own
/// navigation, so a ← is dropped while that confirmation is on screen; ← still
/// works everywhere else (cursor movement, menus).
public enum LeaveSessionGuard {
    static let confirmations = ["← again to", "again to detach"]

    /// `ESC [ D`, or `ESC O D` in application cursor mode.
    public static func isLeftArrow(_ input: [UInt8]) -> Bool {
        input == [0x1B, 0x5B, 0x44] || input == [0x1B, 0x4F, 0x44]
    }

    /// Whether to drop this input, given the terminal's visible lines.
    public static func shouldBlock(input: [UInt8], screen: [String]) -> Bool {
        guard isLeftArrow(input) else { return false }
        return screen.contains { line in confirmations.contains { line.contains($0) } }
    }
}

/// Recognises Claude Code's agents view, which a single ← on an empty prompt
/// switches an attached terminal to, so the app can put the terminal straight
/// back into its session.
public enum AgentsViewDetector {
    /// The agents view sets the terminal title to "claude agents", prefixed
    /// with "N awaiting input · " when sessions need attention.
    public static func isAgentsViewTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed == "claude agents" || trimmed.hasSuffix("· claude agents")
    }

    private static let countsLine = try! NSRegularExpression(pattern: #"\d+ awaiting input · \d+ working · \d+ completed"#)
    private static let sectionHints = [
        "Finished sessions wait here for you to review",
        "they keep running even if you close the terminal",
    ]

    public static func isAgentsViewScreen(_ lines: [String]) -> Bool {
        lines.contains { line in
            if sectionHints.contains(where: line.contains) { return true }
            return countsLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    /// The title is definitive; the list's text only counts right after a ←,
    /// so session content that happens to mention it can't trigger a reattach.
    public static func shouldReturnToSession(title: String?, screen: [String], secondsSinceLeftArrow: TimeInterval?) -> Bool {
        if let title, isAgentsViewTitle(title) { return true }
        guard let seconds = secondsSinceLeftArrow, seconds < 3 else { return false }
        return isAgentsViewScreen(screen)
    }
}
