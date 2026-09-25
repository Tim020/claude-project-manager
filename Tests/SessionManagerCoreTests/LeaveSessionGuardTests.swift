import XCTest
@testable import SessionManagerCore

final class LeaveSessionGuardTests: XCTestCase {
    let left: [UInt8] = [0x1B, 0x5B, 0x44]          // ESC [ D
    let leftApplication: [UInt8] = [0x1B, 0x4F, 0x44] // ESC O D (application cursor mode)

    private func screen(_ hint: String) -> [String] {
        ["╭──────────────────────────╮", "│ >                        │", "╰──────────────────────────╯", "  \(hint)"]
    }

    func testBlocksTheSecondLeftArrowThatWouldLeaveTheSession() {
        for hint in ["Press ← again to go back to agents", "Press ← again to open agents", "Ambiguous ←, press again to detach",
                     "Press ← again to go back"] {
            XCTAssertTrue(LeaveSessionGuard.shouldBlock(input: left, screen: screen(hint)), hint)
            XCTAssertTrue(LeaveSessionGuard.shouldBlock(input: leftApplication, screen: screen(hint)), hint)
        }
    }

    func testLeftArrowOtherwiseReachesTheSession() {
        XCTAssertFalse(LeaveSessionGuard.shouldBlock(input: left, screen: screen("? for shortcuts")))
        XCTAssertFalse(LeaveSessionGuard.shouldBlock(input: left, screen: []))
    }

    func testOtherKeysAndOtherConfirmationsPassThrough() {
        XCTAssertFalse(LeaveSessionGuard.shouldBlock(input: Array("a".utf8), screen: screen("Press ← again to go back to agents")))
        XCTAssertFalse(LeaveSessionGuard.shouldBlock(input: [0x1B, 0x5B, 0x43], screen: screen("Press ← again to go back to agents")), "right arrow")
        XCTAssertFalse(LeaveSessionGuard.shouldBlock(input: left, screen: screen("Press Esc again to go back")), "a different key's confirmation")
    }

    func testRecognisesLeftArrowSequences() {
        XCTAssertTrue(LeaveSessionGuard.isLeftArrow(left))
        XCTAssertTrue(LeaveSessionGuard.isLeftArrow(leftApplication))
        XCTAssertFalse(LeaveSessionGuard.isLeftArrow([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x44]), "option+left moves by word; it doesn't leave")
    }
}
