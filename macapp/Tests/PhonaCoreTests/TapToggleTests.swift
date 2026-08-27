import XCTest
@testable import PhonaCore

final class TapToggleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    func testATapStartsAndTheNextTapStops() {
        var toggle = TapToggle()
        XCTAssertEqual(toggle.optionDown(at: at(0)), .none, "the press alone must not start it")
        XCTAssertEqual(toggle.optionUp(at: at(0.08)), .start)
        XCTAssertTrue(toggle.isRecording)

        XCTAssertEqual(toggle.optionDown(at: at(4)), .none)
        XCTAssertEqual(toggle.optionUp(at: at(4.08)), .stop)
        XCTAssertFalse(toggle.isRecording)
    }

    func testNothingHappensOnThePressItself() {
        var toggle = TapToggle()
        XCTAssertEqual(toggle.optionDown(at: at(0)), .none)
        XCTAssertFalse(toggle.isRecording, "recording may not begin before the key comes up")
    }

    func testRestingOnTheKeyDoesNothing() {
        var toggle = TapToggle()
        _ = toggle.optionDown(at: at(0))
        XCTAssertEqual(toggle.optionUp(at: at(3)), .none, "a hold is not a tap")
        XCTAssertFalse(toggle.isRecording)
    }

    func testTheTapCeilingIsInclusive() {
        var toggle = TapToggle(tapMaxDuration: 0.5)
        _ = toggle.optionDown(at: at(0))
        XCTAssertEqual(toggle.optionUp(at: at(0.5)), .start, "exactly at the ceiling still counts")
    }

    /// The shortcut is why the decision waits for the release. On the press there is no way
    /// to know whether a second key is coming.
    func testAnOptionShortcutNeverStartsADictation() {
        var toggle = TapToggle()
        _ = toggle.optionDown(at: at(0))
        XCTAssertEqual(toggle.otherKeyPressed(), .none)
        XCTAssertEqual(toggle.optionUp(at: at(0.09)), .none)
        XCTAssertFalse(toggle.isRecording)
    }

    func testTheDirtyFlagDoesNotLeakIntoTheNextTap() {
        var toggle = TapToggle()
        _ = toggle.optionDown(at: at(0))
        _ = toggle.otherKeyPressed()
        _ = toggle.optionUp(at: at(0.09))

        _ = toggle.optionDown(at: at(1))
        XCTAssertEqual(toggle.optionUp(at: at(1.08)), .start, "a clean tap after a shortcut works")
    }

    /// Stopping is easier than starting on purpose. A microphone left open is worse than a
    /// dictation that ends a moment early.
    func testAnyReleaseStopsARunningDictation() {
        var toggle = TapToggle()
        _ = toggle.optionDown(at: at(0))
        _ = toggle.optionUp(at: at(0.08))

        _ = toggle.optionDown(at: at(2))
        XCTAssertEqual(toggle.optionUp(at: at(9)), .stop, "a long hold still stops it")
    }

    func testAShortcutDuringADictationIsIgnoredRatherThanAborting() {
        var toggle = TapToggle()
        _ = toggle.optionDown(at: at(0))
        _ = toggle.optionUp(at: at(0.08))

        _ = toggle.optionDown(at: at(3))
        XCTAssertEqual(toggle.otherKeyPressed(), .none)
        XCTAssertTrue(toggle.isRecording, "Option and Tab mid-sentence is not a cancel")
        XCTAssertEqual(toggle.optionUp(at: at(3.2)), .stop)
    }

    func testEscapeAbortsOnlyWhileRecording() {
        var toggle = TapToggle()
        XCTAssertEqual(toggle.escapePressed(), .none, "Escape is an ordinary key when idle")

        _ = toggle.optionDown(at: at(0))
        _ = toggle.optionUp(at: at(0.08))
        XCTAssertEqual(toggle.escapePressed(), .abort)
        XCTAssertFalse(toggle.isRecording)
    }

    func testEscapeLeavesNoHalfPressBehind() {
        var toggle = TapToggle()
        _ = toggle.optionDown(at: at(0))
        _ = toggle.optionUp(at: at(0.08))
        _ = toggle.optionDown(at: at(1))
        _ = toggle.escapePressed()

        XCTAssertEqual(toggle.optionUp(at: at(1.1)), .none,
                       "the release after an abort must not start a new dictation")
    }

    /// The tap can be disabled by the system mid-dictation, so the release that would have
    /// ended it may never arrive.
    func testResetAbortsAnythingInFlight() {
        var toggle = TapToggle()
        XCTAssertEqual(toggle.reset(), .none)

        _ = toggle.optionDown(at: at(0))
        _ = toggle.optionUp(at: at(0.08))
        XCTAssertEqual(toggle.reset(), .abort)
        XCTAssertFalse(toggle.isRecording)
    }

    func testStartAndStopAlternateOverManyTaps() {
        var toggle = TapToggle()
        var actions: [TapAction] = []
        for i in 0..<6 {
            let base = TimeInterval(i) * 2
            _ = toggle.optionDown(at: at(base))
            actions.append(toggle.optionUp(at: at(base + 0.08)))
        }
        XCTAssertEqual(actions, [.start, .stop, .start, .stop, .start, .stop])
    }
}
