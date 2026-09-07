import AppKit
import XCTest
@testable import PhonaCore

/// `Paster` had no tests at all, so every claim about clipboard handling was checked by
/// reading the code. That mattered more than it looked, because `Paster.paste` is where a
/// dictation can be lost: posting Cmd+V reports that the event was sent, not that anything
/// consumed it, so a dictation delivered with nothing focused used to vanish twice over, once
/// because the keystroke went nowhere and once because the clipboard restore overwrote it.
///
/// The decisions now live in `PastePlan`, which needs no Accessibility grant and no real
/// pasteboard, so they can be held here.
final class PastePlanTests: XCTestCase {

    /// The defect: a restore over a keystroke that landed nowhere overwrote the dictation.
    /// Confirming an editable target is the only thing that makes a restore safe.
    func testTheClipboardIsRestoredOnlyForAConfirmedEditableTarget() {
        XCTAssertTrue(PastePlan(restoreRequested: true, target: .editable).restoresClipboard)
        XCTAssertFalse(PastePlan(restoreRequested: true, target: .notEditable).restoresClipboard)
        XCTAssertFalse(
            PastePlan(restoreRequested: true, target: .unknown).restoresClipboard,
            "an unknown target is common in Electron apps, and guessing there is what lost "
                + "dictations")
    }

    /// In Finder, Cmd+V pastes a file. A target that is definitely not editable therefore gets
    /// no keystroke, while an unknown one still does, since refusing on uncertainty would
    /// refuse to type into every app that exposes little of its hierarchy.
    func testAConfirmedNonTargetGetsNoKeystrokeButAnUnknownOneDoes() {
        XCTAssertTrue(PastePlan(restoreRequested: true, target: .editable).sendsKeystroke)
        XCTAssertFalse(PastePlan(restoreRequested: true, target: .notEditable).sendsKeystroke)
        XCTAssertTrue(PastePlan(restoreRequested: true, target: .unknown).sendsKeystroke)
    }

    /// `Insert and copy` depends on this. It is insert without the final restore, which is
    /// exactly what leaves the dictation on the clipboard for Universal Clipboard to carry to
    /// another device.
    func testRestoreFalseLeavesTheDictationOnTheClipboard() {
        let plan = PastePlan(restoreRequested: false, target: .editable)
        XCTAssertFalse(plan.restoresClipboard)
        XCTAssertTrue(plan.sendsKeystroke, "the text still has to be inserted")
    }

    /// Reading every representation of every item is not free, so it happens only when the
    /// bytes are going to be put back. The snapshot and the restore must never disagree about
    /// that, or a path takes the cost and throws the result away.
    func testTheSnapshotIsTakenExactlyWhenItWillBePutBack() {
        for target: PasteTarget in [.editable, .notEditable, .unknown] {
            for requested in [true, false] {
                let plan = PastePlan(restoreRequested: requested, target: target)
                XCTAssertEqual(plan.takesSnapshot, plan.restoresClipboard,
                               "\(target) with restore \(requested)")
            }
        }
    }

    /// Regression: skipping the snapshot on the no-restore paths was right, and taking the
    /// warning with it was not. A displaced image went silently where before it was reported.
    func testAPathWithNoSnapshotStillHasSomewhereToGetAWarningFrom() {
        let plan = PastePlan(restoreRequested: false, target: .editable)
        XCTAssertFalse(plan.warningComesFromSnapshot,
                       "with no snapshot the warning has to come from the advertised types")
    }
}

/// The `Copy to clipboard` setting wrote to `NSPasteboard` directly from its caller, which
/// made it the one output mode that could destroy a copied image or file without saying so.
/// Both insert modes warned, because both went through `Paster.paste`.
final class ClipboardReplacementWarningTests: XCTestCase {

    /// A private pasteboard, never the general one. These tests would otherwise destroy
    /// whatever the person running them had copied, which is the very bug under test.
    private var board: NSPasteboard!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: NSPasteboard.Name("com.basalona.phona.tests.replacement"))
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

    func testAnImageAboutToBeReplacedIsReported() {
        let item = NSPasteboardItem()
        item.setData(Self.png, forType: .png)
        XCTAssertTrue(board.writeObjects([item]))

        XCTAssertNotNil(ClipboardStore.replacementWarning(for: board),
                        "an image cannot be put back, so losing it has to be said out loud")
    }

    /// Silent for text on purpose. A line of text is recoverable from wherever it was copied,
    /// and warning on every dictation would be noise nobody reads.
    func testPlainTextIsReplacedSilently() {
        board.clearContents()
        XCTAssertTrue(board.setString("something I had copied", forType: .string))

        XCTAssertNil(ClipboardStore.replacementWarning(for: board))
    }

    /// A clipboard can be textual without handing over `.string`, as RTF or HTML or UTF-16
    /// can. Calling that an image would have been a confident lie in a notification.
    func testRichTextCountsAsTextRatherThanAsSomethingLost() {
        let item = NSPasteboardItem()
        item.setData(Data("{\\rtf1}".utf8), forType: .rtf)
        XCTAssertTrue(board.writeObjects([item]))

        XCTAssertNil(ClipboardStore.replacementWarning(for: board))
    }

    /// An empty clipboard is not a loss. Reporting one showed a warning every time somebody
    /// dictated with nothing copied.
    func testAnEmptyClipboardIsNotALoss() {
        XCTAssertNil(ClipboardStore.replacementWarning(for: board))
    }
}
