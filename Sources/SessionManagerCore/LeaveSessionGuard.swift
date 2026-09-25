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
