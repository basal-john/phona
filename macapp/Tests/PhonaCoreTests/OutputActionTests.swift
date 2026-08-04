import XCTest
@testable import PhonaCore

final class OutputActionTests: XCTestCase {

    /// The raw values are the strings already written to config.json by earlier versions,
    /// so renaming one would silently reset a user's choice on upgrade.
    func testRawValuesMatchTheConfigStrings() {
        XCTAssertEqual(OutputAction.insert.rawValue, "insert")
        XCTAssertEqual(OutputAction.clipboard.rawValue, "clipboard")
        XCTAssertEqual(OutputAction.both.rawValue, "both")
    }

    func testKnownValuesParse() {
        XCTAssertEqual(OutputAction.from(configValue: "insert"), .insert)
        XCTAssertEqual(OutputAction.from(configValue: "clipboard"), .clipboard)
        XCTAssertEqual(OutputAction.from(configValue: "both"), .both)
    }

    /// A config from a newer version, or a hand-edited typo, must not land the user in
    /// clipboard-only mode, where dictation silently stops reaching the cursor.
    func testUnknownAndMissingValuesFallBackToInserting() {
        XCTAssertEqual(OutputAction.from(configValue: nil), .insert)
        XCTAssertEqual(OutputAction.from(configValue: ""), .insert)
        XCTAssertEqual(OutputAction.from(configValue: "Insert"), .insert)
        XCTAssertEqual(OutputAction.from(configValue: "paste-somewhere-new"), .insert)
    }

    /// Both modes that reach the cursor must report that they do, or the paste path is
    /// skipped and the text only ever lands on the clipboard.
    func testBothAndInsertReachTheCursorButClipboardDoesNot() {
        XCTAssertTrue(OutputAction.insert.insertsAtCursor)
        XCTAssertTrue(OutputAction.both.insertsAtCursor)
        XCTAssertFalse(OutputAction.clipboard.insertsAtCursor)
    }

    /// Only `both` suppresses the clipboard restore. If `insert` ever reported true here it
    /// would start destroying whatever the user had copied on every single dictation.
    func testOnlyBothKeepsTheDictationOnTheClipboard() {
        XCTAssertTrue(OutputAction.both.keepsOnClipboard)
        XCTAssertFalse(OutputAction.insert.keepsOnClipboard)
        XCTAssertFalse(OutputAction.clipboard.keepsOnClipboard)
    }

    func testEveryCaseRoundTripsThroughItsRawValue() {
        for action in OutputAction.allCases {
            XCTAssertEqual(OutputAction.from(configValue: action.rawValue), action)
        }
    }
}
