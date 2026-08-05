import AppKit
import XCTest
@testable import PhonaCore

final class ClipboardSnapshotTests: XCTestCase {

    /// A private pasteboard, never the general one. These tests would otherwise destroy
    /// whatever the person running them had copied, which is the very bug under test.
    private var board: NSPasteboard!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: NSPasteboard.Name("com.basalona.phona.tests"))
        board.clearContents()
    }

    override func tearDown() {
        board.clearContents()
        board = nil
        super.tearDown()
    }

    private static let png = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    ])

    /// The defect: a dictation taken while an image was on the clipboard destroyed it. The
    /// image has to survive the round trip, since restoring text alone is what lost it.
    func testAnImageSurvivesBeingDisplacedByADictation() {
        let item = NSPasteboardItem()
        item.setData(Self.png, forType: .png)
        XCTAssertTrue(board.writeObjects([item]))

        let snapshot = ClipboardStore.snapshot(of: board)
        XCTAssertTrue(snapshot.canRestore)
        XCTAssertEqual(snapshot.loss, .none)
        XCTAssertNil(snapshot.warning, "an image is copyable, so there is nothing to warn about")

        board.clearContents()
        board.setString("the dictated text", forType: .string)
        XCTAssertNil(board.data(forType: .png))

        XCTAssertTrue(ClipboardStore.restore(snapshot, to: board))
        XCTAssertEqual(board.data(forType: .png), Self.png)
    }

    func testTextStillRoundTrips() {
        board.setString("what the user had copied", forType: .string)
        let snapshot = ClipboardStore.snapshot(of: board)

        board.clearContents()
        board.setString("the dictated text", forType: .string)
        ClipboardStore.restore(snapshot, to: board)

        XCTAssertEqual(board.string(forType: .string), "what the user had copied")
    }

    /// One item carrying several representations has to come back with all of them, in the
    /// order the pasteboard reported, because that order is the preference list a receiving
    /// app walks when it picks one.
    func testEveryRepresentationOfAnItemComesBackInOrder() {
        let item = NSPasteboardItem()
        item.setString("a caption", forType: .string)
        item.setData(Self.png, forType: .png)
        board.writeObjects([item])

        let reportedOrder = (board.pasteboardItems ?? []).first?.types.map(\.rawValue) ?? []
        let snapshot = ClipboardStore.snapshot(of: board)

        board.clearContents()
        board.setString("the dictated text", forType: .string)
        ClipboardStore.restore(snapshot, to: board)

        XCTAssertEqual(board.string(forType: .string), "a caption")
        XCTAssertEqual(board.data(forType: .png), Self.png)
        XCTAssertEqual((board.pasteboardItems ?? []).first?.types.map(\.rawValue), reportedOrder)
    }

    func testSeveralItemsAreAllRestored() {
        let first = NSPasteboardItem()
        first.setString("one", forType: .string)
        let second = NSPasteboardItem()
        second.setData(Self.png, forType: .png)
        board.writeObjects([first, second])

        let snapshot = ClipboardStore.snapshot(of: board)
        XCTAssertEqual(snapshot.items.count, 2)

        board.clearContents()
        board.setString("the dictated text", forType: .string)
        ClipboardStore.restore(snapshot, to: board)

        XCTAssertEqual((board.pasteboardItems ?? []).count, 2)
    }

    /// An empty clipboard is not a loss. Reporting one would put a warning in front of the
    /// user every time they dictated with nothing copied.
    func testAnEmptyClipboardIsNotALoss() {
        let snapshot = ClipboardStore.snapshot(of: board)
        XCTAssertFalse(snapshot.canRestore)
        XCTAssertEqual(snapshot.loss, .none)
        XCTAssertNil(snapshot.warning)
        XCTAssertFalse(ClipboardStore.restore(snapshot, to: board), "nothing to put back")
    }

    /// What a promised file looks like: a type is advertised and the bytes never arrive.
    /// This is the only case that still deserves the old warning.
    func testAnItemThatHandsOverNothingIsReportedAsUnreadable() {
        let snapshot = ClipboardSnapshot.from([[(type: "public.file-promise", data: nil)]])
        XCTAssertFalse(snapshot.canRestore)
        XCTAssertEqual(snapshot.loss, .unreadable)
        XCTAssertNotNil(snapshot.warning)
    }

    func testOneUnreadableItemAmongReadableOnesIsPartial() {
        let snapshot = ClipboardSnapshot.from([
            [(type: "public.utf8-plain-text", data: Data("kept".utf8))],
            [(type: "public.file-promise", data: nil)],
        ])
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.loss, .partial)
        XCTAssertNotNil(snapshot.warning)
    }

    /// An item advertising no types at all had nothing to lose, so it is neither restored
    /// nor counted against the user as a loss.
    func testAnItemWithNoTypesIsNotCountedAsALoss() {
        let snapshot = ClipboardSnapshot.from([[]])
        XCTAssertFalse(snapshot.canRestore)
        XCTAssertEqual(snapshot.loss, .none)
        XCTAssertNil(snapshot.warning)
    }

    /// Hitting the cap abandons the whole snapshot. A clipboard restored down to its first
    /// few items looks intact and is not.
    func testTooLargeRestoresNothingAndSaysSo() {
        XCTAssertFalse(ClipboardSnapshot.tooLarge.canRestore)
        XCTAssertEqual(ClipboardSnapshot.tooLarge.items, [])
        XCTAssertTrue(ClipboardSnapshot.tooLarge.warning?.contains("32 MB") == true)
    }
}
