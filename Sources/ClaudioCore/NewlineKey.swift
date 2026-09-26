import Foundation

/// Makes Shift+Enter insert a newline in Claude Code's prompt instead of submitting.
///
/// SwiftTerm's legacy key encoding sends a bare CR for Enter whatever the
/// modifiers, so Claude Code can't tell Shift+Enter from Enter. A CR sent for
/// Shift+Enter becomes ESC CR, the Meta+Enter (Option+Enter) that Claude Code
/// treats as a newline. When Claude Code has turned on the kitty keyboard
/// protocol, SwiftTerm already reports the Shift (`ESC [ 13 ; 2 u`), which
/// isn't a bare CR and so passes through untouched.
///
/// `claude attach` (2.1.283) never turns the kitty protocol on for Claudio: unlike
/// a plain `claude`, it doesn't ask the terminal (`CSI ? u`), and only enables it
/// for a `TERM_PROGRAM` it knows (iTerm.app, kitty, WezTerm, ghostty, …). ESC CR
/// was checked through `claude attach` in a pseudo-terminal: it adds a line.
public enum NewlineKey {
    /// ESC CR.
    public static let metaEnter: [UInt8] = [0x1B, 0x0D]

    /// The bytes to send in place of `input`, or nil to send it as is.
    /// `isReturnKey` and the modifiers describe the key press that produced it.
    public static func replacement(for input: [UInt8], isReturnKey: Bool,
                                   shift: Bool, command: Bool, control: Bool, option: Bool) -> [UInt8]? {
        guard input == [0x0D], isReturnKey, shift, !command, !control, !option else { return nil }
        return metaEnter
    }
}
