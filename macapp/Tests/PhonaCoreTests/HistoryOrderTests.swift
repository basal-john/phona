import XCTest
@testable import PhonaCore

final class HistoryOrderTests: XCTestCase {

    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func line(_ ts: String, _ text: String) -> String {
        """
        {"ts": "\(ts)", "source": "voice", "seconds": 5, "stt_secs": 1, "llm_secs": 1, \
        "raw": "\(text)", "text": "\(text)", "guarded": false, "trimmed": false}
        """
    }

    private func rows(_ contents: String) -> [HistoryRow] {
        HistoryParser.rows(from: contents, timeZone: Self.berlin)
    }

    /// The engine stamps a whole second, so two dictations a fraction apart carry the same
    /// `ts`. Ordering on that stamp leaves the tie to `sorted`, which is not stable, and the
    /// row at the front is the row the app offers to flag.
    func testRowsSharingATimestampKeepFileOrder() {
        let parsed = rows("""
        \(line("2026-09-08T09:00:00", "first"))
        \(line("2026-09-08T09:00:00", "second"))
        \(line("2026-09-08T09:00:00", "third"))
        """)

        let ordered = HistoryOrder.newestFirst(parsed)

        XCTAssertEqual(ordered.map(\.text), ["third", "second", "first"])
    }

    /// The same input has to give the same front row every time, because a front row that
    /// moves between loads means flagging a dictation nobody was looking at.
    func testOrderIsTheSameOnEveryPass() {
        let parsed = rows((0..<40).map { _ in line("2026-09-08T09:00:00", "same") }.joined(separator: "\n"))
        let first = HistoryOrder.newestFirst(parsed)
        let second = HistoryOrder.newestFirst(parsed)

        XCTAssertEqual(first, second)
    }

    /// The archives are concatenated oldest first and the live file goes last, so the last
    /// element of that array is the last line of history.jsonl, which is the only row the
    /// daemon's FLAG command can act on.
    func testTheLastLineOfTheLiveFileIsTheFrontRow() {
        let parsed = rows("""
        \(line("2026-09-08T09:00:00", "archived"))
        \(line("2026-09-07T09:00:00", "written later with an earlier stamp"))
        """)

        XCTAssertEqual(HistoryOrder.newestFirst(parsed).first?.text,
                       "written later with an earlier stamp")
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertTrue(HistoryOrder.newestFirst([]).isEmpty)
    }
}
