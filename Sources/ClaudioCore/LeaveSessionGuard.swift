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

/// Keeps Ctrl+C and Ctrl+D from quitting Claude Code in a session's terminal.
///
/// On an empty prompt, the first press shows "Press Ctrl-C again to exit" (or
/// "Ctrl-D") and a second quits, which would leave the tab on a dead terminal.
/// The app has Stop and close-tab for that, so the second press is dropped:
/// while the confirmation is on screen, or within a second of the first press
/// in case it isn't drawn yet. A single press still interrupts Claude or
/// clears the prompt.
public enum ExitKeyGuard {
    public enum Key: Equatable, Sendable { case ctrlC, ctrlD }

    static let confirmations = ["Ctrl-C again to exit", "Ctrl-D again to exit"]
    public static let repeatWindow: TimeInterval = 1

    /// The key, as plain control bytes, the kitty keyboard protocol
    /// (`ESC [ 99 ; 5 u`) or xterm's modifyOtherKeys (`ESC [ 27 ; 5 ; 99 ~`),
    /// which Claude Code can switch the terminal into.
    public static func exitKey(_ input: [UInt8]) -> Key? {
        switch input {
        case [0x03]: return .ctrlC
        case [0x04]: return .ctrlD
        default: break
        }
        switch String(decoding: input, as: UTF8.self) {
        case "\u{1B}[99;5u", "\u{1B}[27;5;99~": return .ctrlC
        case "\u{1B}[100;5u", "\u{1B}[27;5;100~": return .ctrlD
        default: return nil
        }
    }

    public static func shouldBlock(input: [UInt8], screen: [String], secondsSinceSameKey: TimeInterval?) -> Bool {
        guard exitKey(input) != nil else { return false }
        if screen.contains(where: { line in confirmations.contains { line.contains($0) } }) { return true }
        if let seconds = secondsSinceSameKey, seconds < repeatWindow { return true }
        return false
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
