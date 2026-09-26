import XCTest
@testable import ClaudioCore

final class NewlineKeyTests: XCTestCase {
    private func replacement(_ input: [UInt8] = [0x0D], isReturn: Bool = true, shift: Bool = true,
                             command: Bool = false, control: Bool = false, option: Bool = false) -> [UInt8]? {
        NewlineKey.replacement(for: input, isReturnKey: isReturn, shift: shift,
                               command: command, control: control, option: option)
    }

    func testShiftEnterSendsMetaEnter() {
        XCTAssertEqual(replacement(), [0x1B, 0x0D])
    }

    func testPlainEnterIsUntouched() {
        XCTAssertNil(replacement(shift: false))
    }

    func testOtherModifierCombinationsAreUntouched() {
        XCTAssertNil(replacement(command: true), "⇧⌘↩ is the Resume Session shortcut")
        XCTAssertNil(replacement(control: true))
        XCTAssertNil(replacement(option: true))
    }

    func testKittyProtocolEncodingPassesThrough() {
        XCTAssertNil(replacement(Array("\u{1B}[13;2u".utf8)), "SwiftTerm already reports the Shift")
    }

    func testOnlyAReturnKeyPressIsReplaced() {
        XCTAssertNil(replacement(isReturn: false), "a CR from anything else, such as a paste")
        XCTAssertNil(replacement([0x0D, 0x0D]))
    }
}
