import XCTest
@testable import PhonaCore

final class OptionKeyTests: XCTestCase {

    /// Both keys set `maskAlternate`, which is why watching that mask alone made the right
    /// key start dictations.
    private let leftOnly = OptionKey.eitherMask | OptionKey.leftMask
    private let rightOnly = OptionKey.eitherMask | OptionKey.rightMask
    private let bothKeys = OptionKey.eitherMask | OptionKey.leftMask | OptionKey.rightMask

    func testTheKeycodesNameTheSides() {
        XCTAssertEqual(OptionKey.side(ofKeycode: 58), .left)
        XCTAssertEqual(OptionKey.side(ofKeycode: 61), .right)
        XCTAssertNil(OptionKey.side(ofKeycode: 56), "that is shift")
        XCTAssertNil(OptionKey.side(ofKeycode: 55), "that is command")
    }

    func testEachSideIsReadFromItsOwnBit() {
        XCTAssertTrue(OptionKey.leftIsDown(flags: leftOnly))
        XCTAssertFalse(OptionKey.rightIsDown(flags: leftOnly))

        XCTAssertTrue(OptionKey.rightIsDown(flags: rightOnly))
        XCTAssertFalse(OptionKey.leftIsDown(flags: rightOnly))

        XCTAssertTrue(OptionKey.leftIsDown(flags: bothKeys))
        XCTAssertTrue(OptionKey.rightIsDown(flags: bothKeys))
    }

    /// The fix itself. The right key must never arm a dictation, under any combination.
    func testOnlyTheLeftKeyStartsADictation() {
        XCTAssertTrue(OptionKey.dictationSideIsDown(flags: leftOnly))
        XCTAssertFalse(OptionKey.dictationSideIsDown(flags: rightOnly))
        XCTAssertTrue(OptionKey.dictationSideIsDown(flags: bothKeys),
                      "the left key is held, whatever else is")
    }

    /// Every flag combination that does not include the left bit has to be refused, so no
    /// stray modifier can smuggle the right key back in.
    func testNoCombinationWithoutTheLeftBitArms() {
        let otherFlags: [UInt64] = [
            0, 0x0001_0000, 0x0002_0000, 0x0004_0000, 0x0010_0000, 0x0080_0000,
            OptionKey.eitherMask, OptionKey.rightMask,
        ]
        for base in otherFlags {
            for extra in otherFlags {
                let flags = base | extra
                XCTAssertFalse(OptionKey.dictationSideIsDown(flags: flags),
                               String(format: "%#010llx has no left bit", flags))
            }
        }
    }

    /// No fallback. Option with no side bit could be either key, and treating it as the left
    /// one would let the right key start dictations again on that keyboard.
    func testOptionWithNoSideBitDoesNotArm() {
        XCTAssertFalse(OptionKey.dictationSideIsDown(flags: OptionKey.eitherMask))
        XCTAssertTrue(OptionKey.optionWithoutSide(flags: OptionKey.eitherMask))
    }

    func testASidedOptionIsNotReportedAsSideless() {
        XCTAssertFalse(OptionKey.optionWithoutSide(flags: leftOnly))
        XCTAssertFalse(OptionKey.optionWithoutSide(flags: rightOnly))
        XCTAssertFalse(OptionKey.optionWithoutSide(flags: 0))
    }

    func testNoOptionAtAllIsNotADictation() {
        XCTAssertFalse(OptionKey.dictationSideIsDown(flags: 0))
        XCTAssertFalse(OptionKey.dictationSideIsDown(flags: 0x0001_0000), "that is shift alone")
    }

    /// The right key has to read as an ordinary modifier so it cancels an arming hold the
    /// way command or shift does.
    func testTheRightKeyAloneIsAnOrdinaryModifier() {
        XCTAssertTrue(OptionKey.onlyRightIsDown(flags: rightOnly))
        XCTAssertFalse(OptionKey.onlyRightIsDown(flags: leftOnly))
        XCTAssertFalse(OptionKey.onlyRightIsDown(flags: bothKeys), "the left key is down too")
        XCTAssertFalse(OptionKey.onlyRightIsDown(flags: 0))
    }

    /// The bit values are IOKit's, so a typo would be invisible in behaviour on this machine
    /// and wrong on another.
    func testTheMasksAreTheDocumentedOnes() {
        XCTAssertEqual(OptionKey.leftMask, 0x0000_0020, "NX_DEVICELALTKEYMASK")
        XCTAssertEqual(OptionKey.rightMask, 0x0000_0040, "NX_DEVICERALTKEYMASK")
        XCTAssertEqual(OptionKey.eitherMask, 0x0008_0000, "CGEventFlags.maskAlternate")
    }
}
