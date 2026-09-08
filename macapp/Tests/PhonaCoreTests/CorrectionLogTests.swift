import XCTest
@testable import PhonaCore

/// Joining `corrections.jsonl` to the one dictation each flag points at.
final class CorrectionLogTests: XCTestCase {

    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func rows(_ contents: String) -> [HistoryRow] {
        HistoryParser.rows(from: contents, timeZone: Self.berlin)
    }

    private func historyLine(_ ts: String, raw: String, text: String) -> String {
        """
        {"ts": "\(ts)", "source": "voice", "seconds": 5, "stt_secs": 1, "llm_secs": 1, \
        "raw": "\(raw)", "text": "\(text)", "guarded": false, "trimmed": 0}
        """
    }

    private func flagLine(_ ts: String,
                          heard: String,
                          returned: String,
                          actual: String) -> String {
        """
        {"flagged_at": "\(ts)", "ts": "\(ts)", "heard": "\(heard)", \
        "returned": "\(returned)", "actual": "\(actual)", "mode": "correct", \
        "source": "voice"}
        """
    }

    /// The finding. The engine stamps a whole second, so two dictations a fraction apart
    /// share one `ts`. Keying a flag on that alone marked both rows as flagged and printed
    /// one row's ground truth under the other one's transcript.
    func testAFlagLandsOnOneOfTwoRowsSharingASecond() {
        let parsed = rows("""
        \(historyLine("2026-09-08T09:00:00", raw: "the tests is failing",
                      text: "The tests are failing."))
        \(historyLine("2026-09-08T09:00:00", raw: "meet me at four",
                      text: "Meet me at four."))
        """)
        let flags = CorrectionLog.flags(from: flagLine("2026-09-08T09:00:00",
                                                       heard: "meet me at four",
                                                       returned: "Meet me at four.",
                                                       actual: "meet me at two"),
                                        timeZone: Self.berlin)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertNil(flags[CorrectionLog.key(for: parsed[0])],
                     "the unflagged row picked up its neighbour's flag")
        XCTAssertEqual(flags[CorrectionLog.key(for: parsed[1])]?.actual, "meet me at two")
    }

    /// A flag whose stamp matches but whose transcript does not belongs to a row in another
    /// archive, or to one the engine has since rewritten. It joins nothing.
    func testAFlagWithADifferentTranscriptJoinsNothing() {
        let parsed = rows(historyLine("2026-09-08T09:00:00", raw: "the tests is failing",
                                      text: "The tests are failing."))
        let flags = CorrectionLog.flags(from: flagLine("2026-09-08T09:00:00",
                                                       heard: "something else entirely",
                                                       returned: "Something else entirely.",
                                                       actual: "no"),
                                        timeZone: Self.berlin)

        XCTAssertNil(flags[CorrectionLog.key(for: parsed[0])])
    }

    func testAFlagJoinsTheRowItWasWrittenFrom() {
        let parsed = rows(historyLine("2026-09-08T09:00:00", raw: "the tests is failing",
                                      text: "The tests are failing."))
        let flags = CorrectionLog.flags(from: flagLine("2026-09-08T09:00:00",
                                                       heard: "the tests is failing",
                                                       returned: "The tests are failing.",
                                                       actual: "the test is failing"),
                                        timeZone: Self.berlin)

        let flag = flags[CorrectionLog.key(for: parsed[0])]
        XCTAssertEqual(flag?.actual, "the test is failing")
        XCTAssertNotNil(flag?.flaggedAt)
    }

    /// A speaker who flags twice is correcting their own first attempt, so the later record
    /// wins. That held when the key was the stamp and it has to keep holding.
    func testALaterFlagOnTheSameRowWins() {
        let parsed = rows(historyLine("2026-09-08T09:00:00", raw: "heard", text: "Heard."))
        let flags = CorrectionLog.flags(from: """
        \(flagLine("2026-09-08T09:00:00", heard: "heard", returned: "Heard.", actual: "first"))
        \(flagLine("2026-09-08T09:00:00", heard: "heard", returned: "Heard.", actual: "second"))
        """, timeZone: Self.berlin)

        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags[CorrectionLog.key(for: parsed[0])]?.actual, "second")
    }

    /// A flag with no typed correction still carries the signal that something was wrong,
    /// and an unreadable line may not cost the rest of the file.
    func testAFlagWithoutATypedCorrectionAndABadLine() {
        let parsed = rows(historyLine("2026-09-08T09:00:00", raw: "heard", text: "Heard."))
        let flags = CorrectionLog.flags(from: """
        not json at all
        {"ts": "not a stamp", "heard": "heard", "returned": "Heard."}
        {"flagged_at": "2026-09-08T09:00:01", "ts": "2026-09-08T09:00:00", \
        "heard": "heard", "returned": "Heard.", "actual": null}
        """, timeZone: Self.berlin)

        XCTAssertEqual(flags.count, 1)
        let flag = flags[CorrectionLog.key(for: parsed[0])]
        XCTAssertNotNil(flag)
        XCTAssertNil(flag?.actual)
    }
}
