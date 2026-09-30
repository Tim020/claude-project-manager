import Foundation

/// Mac key handling that SwiftTerm gets wrong, for session terminals and shells.
///
/// SwiftTerm treats Option as Meta for every key, so Option+3 sends ESC 3.
/// On a British layout that's how you type `#`, and other layouts put `@`,
/// `|`, `[`, `{`, `~` and `\` behind Option too. Claude Code's own Alt
/// shortcuts (Alt+P, Alt+T, Alt+O, the word keys Alt+B/F/D/⌫) sit on letters
/// whose Option character isn't ASCII, so Option stays Meta there, and types
/// its character where a layout uses it for ASCII punctuation, on the digit
/// row (UK Option+2 is `€`) and for dead keys (Option+E then E types `é`).
/// Claude Code 2.1.285 binds none of those as Alt shortcuts.
///
/// It also fixes a few keys (only while the kitty keyboard protocol is off,
/// since with it on SwiftTerm reports them in full):
/// - Option+←/→ sent `ESC [1;3D`, which bash and zsh don't bind (the Shell
///   panel printed `;3D`). They send `ESC b` / `ESC f`, the word moves both
///   readline and Claude Code know.
/// - ⌘←/→ moved a word, and ⌘⌫ sent nothing. They send Ctrl+A, Ctrl+E and
///   Ctrl+U (start of line, end of line, delete to start), as in Ghostty.
public enum TerminalKeys {
    /// A key press, from `NSEvent`.
    public struct Press: Equatable, Sendable {
        public var keyCode: UInt16
        /// The characters typed, with Option applied: empty for a dead key.
        public var characters: String
        /// The key's own character (with Shift, without Option).
        public var charactersIgnoringModifiers: String
        public var shift = false
        public var control = false
        public var option = false
        public var command = false

        public init(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String,
                    shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
            self.keyCode = keyCode
            self.characters = characters
            self.charactersIgnoringModifiers = charactersIgnoringModifiers
            self.shift = shift
            self.control = control
            self.option = option
            self.command = command
        }
    }

    public enum Action: Equatable, Sendable {
        /// Send these bytes instead of the key.
        case send([UInt8])
        /// Let SwiftTerm handle the key, with Option as Meta or not.
        case optionAsMeta(Bool)
        /// Leave the key alone.
        case none
    }

    // Virtual key codes (kVK_…), which don't depend on the layout.
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let delete: UInt16 = 51

    /// What to do with `press`. `enhancedKeyboard` is whether the program has
    /// turned on the kitty keyboard protocol.
    public static func action(for press: Press, enhancedKeyboard: Bool) -> Action {
        let onlyCommand = press.command && !press.option && !press.control && !press.shift
        let onlyOption = press.option && !press.command && !press.control && !press.shift
        if !enhancedKeyboard, onlyCommand {
            switch press.keyCode {
            case leftArrow: return .send([0x01])
            case rightArrow: return .send([0x05])
            case delete: return .send([0x15])
            default: return .none
            }
        }
        if !enhancedKeyboard, onlyOption {
            switch press.keyCode {
            case leftArrow: return .send([0x1B, UInt8(ascii: "b")])
            case rightArrow: return .send([0x1B, UInt8(ascii: "f")])
            default: break
            }
        }
        guard press.option, !press.command, !press.control else { return .none }
        return .optionAsMeta(!optionTypesCharacter(press))
    }

    /// Whether Option, for this key, picks a character to type rather than
    /// acting as Meta.
    static func optionTypesCharacter(_ press: Press) -> Bool {
        // A dead key: the next key press types the accented letter.
        if press.characters.isEmpty { return true }
        let typed = press.characters.unicodeScalars
        guard typed.allSatisfy(isPrintable), press.characters != press.charactersIgnoringModifiers else { return false }
        let base = press.charactersIgnoringModifiers.unicodeScalars
        if !base.isEmpty, base.allSatisfy({ ("0"..."9").contains($0) }) { return true }
        return typed.allSatisfy { $0.isASCII }
    }

    /// Not a control character, nor one of AppKit's function-key characters
    /// (U+F700–U+F8FF, which arrow and function keys report).
    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0..<0x20, 0x7F...0x9F, 0xF700...0xF8FF: return false
        default: return true
        }
    }
}
