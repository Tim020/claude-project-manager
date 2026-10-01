import XCTest
@testable import ClaudioCore

final class TerminalKeysTests: XCTestCase {
    private func action(_ characters: String, _ base: String, keyCode: UInt16 = 0, shift: Bool = false,
                        control: Bool = false, option: Bool = true, command: Bool = false,
                        enhanced: Bool = false) -> TerminalKeys.Action {
        TerminalKeys.action(for: .init(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: base,
                                       shift: shift, control: control, option: option, command: command),
                            enhancedKeyboard: enhanced)
    }

    private let typesCharacter = TerminalKeys.Action.optionAsMeta(false)
    private let meta = TerminalKeys.Action.optionAsMeta(true)

    func testOptionTypesASCIIPunctuationALayoutPutsBehindIt() {
        XCTAssertEqual(action("#", "3"), typesCharacter, "British Option+3")
        XCTAssertEqual(action("@", "l"), typesCharacter, "German Option+L")
        XCTAssertEqual(action("|", "7"), typesCharacter, "German Option+7")
        XCTAssertEqual(action("|", "L", shift: true), typesCharacter, "French Option+Shift+L")
        XCTAssertEqual(action("#", "3", enhanced: true), typesCharacter, "with the kitty protocol too")
    }

    func testOptionTypesAnyCharacterOnTheDigitRow() {
        XCTAssertEqual(action("€", "2", keyCode: 19), typesCharacter, "British Option+2")
        XCTAssertEqual(action("£", "3", keyCode: 20), typesCharacter, "US Option+3")
        XCTAssertEqual(action("€", "@", keyCode: 19, shift: true), typesCharacter, "US Option+Shift+2")
        XCTAssertEqual(action("“", "&", keyCode: 18), typesCharacter, "AZERTY's digit row has no digits")
    }

    func testOptionTypesTheLayoutsLetters() {
        XCTAssertEqual(action("ą", "a"), typesCharacter, "Polish Pro Option+A")
        XCTAssertEqual(action("ł", "l"), typesCharacter, "Polish Pro Option+L")
        XCTAssertEqual(action("Ś", "S", shift: true), typesCharacter, "Polish Pro Option+Shift+S")
        XCTAssertEqual(action("ß", "s"), typesCharacter, "US Option+S")
    }

    func testDeadKeysCompose() {
        XCTAssertEqual(action("", "e"), typesCharacter, "Option+E, then E types é")
        XCTAssertEqual(action("", "u"), typesCharacter)
    }

    func testOptionStaysMetaForClaudeCodesShortcuts() {
        XCTAssertEqual(action("π", "p"), meta, "Alt+P picks the model")
        XCTAssertEqual(action("†", "t"), meta, "Alt+T toggles thinking")
        XCTAssertEqual(action("ø", "o"), meta)
        XCTAssertEqual(action("ó", "o"), meta, "Polish Pro gives up ó for Alt+O")
        XCTAssertEqual(action("∑", "w"), meta)
        XCTAssertEqual(action("∫", "b"), meta, "word back")
        XCTAssertEqual(action("∂", "d"), meta, "delete word")
        XCTAssertEqual(action("Π", "P", shift: true), meta)
        XCTAssertEqual(action("≥", "."), meta, "M-. in a shell")
    }

    func testOptionStaysMetaForControlKeys() {
        XCTAssertEqual(action("\r", "\r", keyCode: 36), meta, "Option+Return adds a line")
        XCTAssertEqual(action("\u{7F}", "\u{7F}", keyCode: 51), meta, "Option+⌫ deletes a word")
        XCTAssertEqual(action("\u{F700}", "\u{F700}", keyCode: 126), meta, "Option+↑")
    }

    func testOptionArrowsMoveByWord() {
        XCTAssertEqual(action("\u{F702}", "\u{F702}", keyCode: 123), .send([0x1B, 0x62]))
        XCTAssertEqual(action("\u{F703}", "\u{F703}", keyCode: 124), .send([0x1B, 0x66]))
        XCTAssertEqual(action("\u{F702}", "\u{F702}", keyCode: 123, shift: true), meta, "only plain Option")
        XCTAssertEqual(action("\u{F702}", "\u{F702}", keyCode: 123, enhanced: true), meta,
                       "the kitty protocol reports the key itself")
    }

    func testCommandLineEditingKeys() {
        XCTAssertEqual(action("\u{F702}", "\u{F702}", keyCode: 123, option: false, command: true), .send([0x01]))
        XCTAssertEqual(action("\u{F703}", "\u{F703}", keyCode: 124, option: false, command: true), .send([0x05]))
        XCTAssertEqual(action("\u{7F}", "\u{7F}", keyCode: 51, option: false, command: true), .send([0x15]))
        XCTAssertEqual(action("\u{F702}", "\u{F702}", keyCode: 123, shift: true, option: false, command: true), .none)
        XCTAssertEqual(action("\u{7F}", "\u{7F}", keyCode: 51, option: false, command: true, enhanced: true), .none)
    }

    func testOtherKeysAreLeftAlone() {
        XCTAssertEqual(action("3", "3", option: false), .none)
        XCTAssertEqual(action("c", "c", option: false, command: true), .none, "⌘C copies")
    }

    func testOptionWithControlOrCommandIsAlwaysMeta() {
        XCTAssertEqual(action("\u{1}", "a", control: true), meta, "Ctrl+Option")
        XCTAssertEqual(action("#", "3", command: true), meta, "⌘⌥ shortcuts")
    }
}
