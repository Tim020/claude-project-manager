import Foundation

/// Mac key handling that SwiftTerm gets wrong, for session terminals and shells.
///
/// SwiftTerm treats Option as Meta for every key, so Option+3 sends ESC 3.
/// On a British layout that's how you type `#`, and other layouts put `@`,
/// `|`, `[`, `{`, `~` and `\` behind Option too, and Polish Pro puts its
/// letters there (Option+A is `ą`). So Option types its character, except
/// where it's needed as Meta:
/// - on the letters Claude Code 2.1.285 binds with Alt (P, O, T, W) and the
///   word keys it and readline share (B, F, D, Y), unless the layout puts
///   ASCII there (German Option+L is `@`, but nothing ASCII sits on those);
/// - on punctuation keys whose Option character isn't ASCII (readline's M-.);
/// - for keys that don't type, such as Return and ⌫ (Option+Return adds a line).
/// Dead keys compose (Option+E then E types `é`), and the digit row, matched
/// by position so Option+Shift and AZERTY count, always types (UK Option+2 is `€`).
///
/// It also fixes a few keys (only while the kitty keyboard protocol is off,
/// since with it on SwiftTerm reports them in full):
/// - Option+←/→ sent `ESC [1;3D`, which bash and zsh don't bind (the Shell
///   panel printed `;3D`). They send `ESC b` / `ESC f`, the word moves both
///   readline and Claude Code know.
/// - ⌘←/→ moved a word, and ⌘⌫ sent nothing. They send Ctrl+A, Ctrl+E and
///   Ctrl+U (start of line, end of line, delete to start; zsh deletes the
///   whole line), as in Ghostty.
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
    /// kVK_ANSI_1 … kVK_ANSI_0.
    static let digitRow: Set<UInt16> = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    /// Letters whose Option press stays Meta (see above).
    static let metaLetters: Set<Character> = ["b", "d", "f", "o", "p", "t", "w", "y"]

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
        guard press.option else { return .none }
        // Set every time, so an earlier key's choice doesn't carry over.
        return .optionAsMeta(press.command || press.control || !optionTypesCharacter(press))
    }

    /// Whether Option, for this key, picks a character to type rather than
    /// acting as Meta.
    static func optionTypesCharacter(_ press: Press) -> Bool {
        // A dead key: the next key press types the accented letter.
        if press.characters.isEmpty { return true }
        let typed = press.characters.unicodeScalars
        guard typed.allSatisfy(isPrintable), press.characters != press.charactersIgnoringModifiers else { return false }
        if digitRow.contains(press.keyCode) || typed.allSatisfy({ $0.isASCII }) { return true }
        guard let base = press.charactersIgnoringModifiers.lowercased().first,
              press.charactersIgnoringModifiers.count == 1, base.isLetter else { return false }
        return !metaLetters.contains(base)
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
