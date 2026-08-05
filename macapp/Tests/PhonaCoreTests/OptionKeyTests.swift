import CoreGraphics
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

    /// The right key has to read as an ordinary modifier so it cancels an arming hold the way
    /// command or shift does, and it has to do so whenever it is down.
    func testTheRightKeyIsAnOrdinaryModifierWheneverItIsDown() {
        XCTAssertTrue(OptionKey.otherModifierIsDown(flags: rightOnly))
        XCTAssertTrue(OptionKey.otherModifierIsDown(flags: bothKeys),
                      "still an intruder when the left key is held as well")
        XCTAssertFalse(OptionKey.otherModifierIsDown(flags: leftOnly))
        XCTAssertFalse(OptionKey.otherModifierIsDown(flags: 0))
    }

    /// Holding the left key and then pressing the right one has to cancel. An earlier version
    /// asked whether the right key was the only Option held, so pressing it mid-hold left the
    /// hold running: both side bits were set, and the right key stopped looking like an
    /// intruder at exactly the moment it became one.
    func testPressingTheRightKeyDuringALeftHoldCancels() {
        XCTAssertTrue(OptionKey.armsDictation(flags: leftOnly))
        XCTAssertFalse(OptionKey.armsDictation(flags: bothKeys))
    }

    func testAnyOtherModifierAlsoStopsItArming() {
        for modifier in [0x0002_0000, 0x0004_0000, 0x0010_0000, 0x0080_0000] as [UInt64] {
            XCTAssertFalse(OptionKey.armsDictation(flags: leftOnly | modifier),
                           String(format: "%#010llx joined the hold", modifier))
        }
        XCTAssertFalse(OptionKey.armsDictation(flags: rightOnly))
        XCTAssertFalse(OptionKey.armsDictation(flags: 0))
    }

    /// The other modifier bits are `CGEventFlags` values, so a typo would be invisible in
    /// behaviour here and wrong somewhere else.
    func testTheOtherModifierMaskMatchesCoreGraphics() {
        let expected = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertEqual(OptionKey.otherModifierMask, expected)
        XCTAssertEqual(OptionKey.eitherMask, CGEventFlags.maskAlternate.rawValue)
    }

    /// The bit values are IOKit's, so a typo would be invisible in behaviour on this machine
    /// and wrong on another.
    func testTheMasksAreTheDocumentedOnes() {
        XCTAssertEqual(OptionKey.leftMask, 0x0000_0020, "NX_DEVICELALTKEYMASK")
        XCTAssertEqual(OptionKey.rightMask, 0x0000_0040, "NX_DEVICERALTKEYMASK")
        XCTAssertEqual(OptionKey.eitherMask, 0x0008_0000, "CGEventFlags.maskAlternate")
    }
}
