import XCTest
@testable import PhonaCore

final class InsightsTests: XCTestCase {

    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let utc = TimeZone(identifier: "UTC")!

    private func berlinCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.berlin
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ stamp: String, zone: TimeZone = InsightsTests.berlin) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: stamp)!
    }

    private func words(_ count: Int) -> String {
        (0..<count).map { "w\($0)" }.joined(separator: " ")
    }

    private func voice(_ ts: String,
                       text: String,
                       raw: String? = nil,
                       seconds: Double = 5,
                       stt: Double = 1,
                       llm: Double = 1,
                       backend: String? = nil,
                       mode: String? = nil,
                       llmModel: String? = nil,
                       cloudModel: String? = nil,
                       guarded: Bool = false,
                       trimmed: Bool = false) -> String {
        var fields = [
            "\"ts\": \"\(ts)\"",
            "\"source\": \"voice\"",
            "\"seconds\": \(seconds)",
            "\"stt_secs\": \(stt)",
            "\"llm_secs\": \(llm)",
            "\"raw\": \"\(raw ?? text)\"",
            "\"text\": \"\(text)\"",
            "\"guarded\": \(guarded)",
            "\"trimmed\": \(trimmed)",
            "\"backend\": " + (backend.map { "\"\($0)\"" } ?? "null"),
        ]
        if let mode { fields.append("\"mode\": \"\(mode)\"") }
        if let llmModel { fields.append("\"llm_model\": \"\(llmModel)\"") }
        if let cloudModel { fields.append("\"cloud_model\": \"\(cloudModel)\"") }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    private func typed(_ ts: String, text: String, llm: Double = 1) -> String {
        """
        {"ts": "\(ts)", "source": "text", "seconds": 0, "mode": "correct", \
        "stt_secs": 0, "llm_secs": \(llm), "raw": "\(text)", "text": "\(text)", \
        "guarded": false, "guard_reason": null}
        """
    }

    private func compute(_ contents: String,
                         typing: Double = 40,
                         now: String = "2026-09-08T12:00:00",
                         activityDays: Int = 7) -> Insights {
        Insights.compute(rows: HistoryParser.rows(from: contents, timeZone: Self.berlin),
                         typingWordsPerMinute: typing,
                         calendar: berlinCalendar(),
                         now: date(now),
                         activityDays: activityDays)
    }

    // MARK: - timestamps

    /// The engine writes a naive local wall clock with no zone. Reading it as UTC shifts
    /// every row by the machine's offset, which is how a dictation lands on the wrong day.
    func testNaiveTimestampIsParsedInThePassedZone() {
        let line = voice("2026-07-01T12:00:00", text: words(3))
        let local = HistoryParser.row(from: line, timeZone: Self.berlin)
        let asUTC = HistoryParser.row(from: line, timeZone: Self.utc)
        XCTAssertEqual(asUTC?.ts.timeIntervalSince(local!.ts), 7200)
    }

    /// Europe/Berlin runs 25 hours on 25 October 2026, so a bucket boundary computed by
    /// adding 86400 to the start of that day falls an hour inside it and pulls a 23:30
    /// dictation onto the next day.
    func testTwentyFiveHourDayDoesNotMoveADictationToTheWrongDay() {
        let insights = compute("""
        \(voice("2026-10-25T23:30:00", text: words(4)))
        \(voice("2026-10-26T00:30:00", text: words(6)))
        """, now: "2026-10-26T12:00:00", activityDays: 3)

        XCTAssertEqual(insights.days.count, 3)
        XCTAssertEqual(insights.days[1].day, date("2026-10-25T00:00:00"))
        XCTAssertEqual(insights.days[1].count, 1)
        XCTAssertEqual(insights.days[1].words, 4)
        XCTAssertEqual(insights.days[2].day, date("2026-10-26T00:00:00"))
        XCTAssertEqual(insights.days[2].count, 1)
        XCTAssertEqual(insights.days[2].words, 6)
    }

    /// Proves the window steps by calendar days rather than by a fixed number of seconds.
    func testWindowStepsByCalendarDaysAcrossTheClockChange() {
        let insights = compute("", now: "2026-10-26T12:00:00", activityDays: 3)
        let calendar = berlinCalendar()
        for index in 1..<insights.days.count {
            let step = calendar.dateComponents([.day],
                                               from: insights.days[index - 1].day,
                                               to: insights.days[index].day)
            XCTAssertEqual(step.day, 1)
        }
        let gap = insights.days[2].day.timeIntervalSince(insights.days[1].day)
        XCTAssertEqual(gap, 25 * 3600)
    }

    /// The spring change is the same bug in the other direction, a 23 hour day.
    func testTwentyThreeHourDayIsAlsoOneCalendarDay() {
        let insights = compute("", now: "2026-03-30T12:00:00", activityDays: 3)
        XCTAssertEqual(insights.days[2].day.timeIntervalSince(insights.days[1].day), 23 * 3600)
    }

    // MARK: - what counts as a word, and what counts as speech

    /// `text` is what was delivered, `raw` is what the transcriber heard. The correction
    /// stage adds and removes words, so counting `raw` measures the wrong thing.
    func testWordCountUsesDeliveredTextNotWhatWasHeard() {
        let line = voice("2026-09-08T09:00:00", text: words(3), raw: words(9))
        XCTAssertEqual(HistoryParser.row(from: line, timeZone: Self.berlin)?.wordCount, 3)
        XCTAssertEqual(compute(line).words, 3)
    }

    /// A FIX row was typed, not spoken, and carries `seconds: 0`. It is a real dictation for
    /// counting and can never contribute speaking time or a speaking rate.
    func testTypedRowCountsAsADictationButNeverAsSpeech() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: words(3), seconds: 30))
        \(typed("2026-09-08T10:00:00", text: words(10)))
        """)

        XCTAssertEqual(insights.dictations, 2)
        XCTAssertEqual(insights.spokenDictations, 1)
        XCTAssertEqual(insights.words, 13)
        XCTAssertEqual(insights.spokenWords, 3)
        XCTAssertEqual(insights.spokenSeconds, 30)
        XCTAssertEqual(insights.minutesSpoken, 0.5)
        XCTAssertEqual(insights.spokenWordsPerMinute, 6, accuracy: 0.0001)
    }

    func testIsSpokenIsExactlyTheVoiceSource() {
        let voiceRow = HistoryParser.row(from: voice("2026-09-08T09:00:00", text: "hi"),
                                         timeZone: Self.berlin)
        let typedRow = HistoryParser.row(from: typed("2026-09-08T09:00:00", text: "hi"),
                                         timeZone: Self.berlin)
        XCTAssertEqual(voiceRow?.isSpoken, true)
        XCTAssertEqual(typedRow?.isSpoken, false)
    }

    // MARK: - absent is not empty

    /// `backend` is present-and-null on a local row and absent on an older one. Both mean the
    /// text stayed on the machine, and neither may crash the parser.
    func testAbsentAndNullBackendBothReadAsLocal() {
        let nullBackend = voice("2026-09-08T09:00:00", text: "hi")
        let noBackendKey = """
        {"ts": "2026-09-08T09:00:00", "source": "voice", "seconds": 5, "raw": "hi", "text": "hi"}
        """
        XCTAssertEqual(HistoryParser.row(from: nullBackend, timeZone: Self.berlin)?.route, .local)
        XCTAssertEqual(HistoryParser.row(from: noBackendKey, timeZone: Self.berlin)?.route, .local)
        XCTAssertNil(HistoryParser.row(from: noBackendKey, timeZone: Self.berlin)?.backend)
    }

    /// A cloud request that is refused falls back to the local model and records no backend,
    /// so only a backend proves the text left the machine, never the mode.
    func testOnlyABackendMakesARowCloud() {
        let refused = """
        {"ts": "2026-09-08T09:00:00", "source": "voice", "seconds": 5, "mode": "cloud", \
        "backend": null, "raw": "hi", "text": "hi"}
        """
        let answered = voice("2026-09-08T09:00:00", text: "hi", backend: "claude")
        XCTAssertEqual(HistoryParser.row(from: refused, timeZone: Self.berlin)?.route, .local)
        XCTAssertEqual(HistoryParser.row(from: answered, timeZone: Self.berlin)?.route, .cloud)
    }

    func testAbsentAndNullGuardReasonAreBothNil() {
        let nullReason = """
        {"ts": "2026-09-08T09:00:00", "source": "voice", "seconds": 5, "raw": "hi", \
        "text": "hi", "guard_reason": null}
        """
        let noReasonKey = """
        {"ts": "2026-09-08T09:00:00", "source": "voice", "seconds": 5, "raw": "hi", "text": "hi"}
        """
        XCTAssertNil(HistoryParser.row(from: nullReason, timeZone: Self.berlin)?.guardReason)
        XCTAssertNil(HistoryParser.row(from: noReasonKey, timeZone: Self.berlin)?.guardReason)
    }

    func testRouteCountsCoverBothRoutesEvenWhenOneIsUnused() {
        let insights = compute(voice("2026-09-08T09:00:00", text: "hi"))
        XCTAssertEqual(insights.routeCounts[.local], 1)
        XCTAssertEqual(insights.routeCounts[.cloud], 0)
    }

    // MARK: - unusable lines

    /// One bad line must never cost the whole file.
    func testUnusableLinesAreSkippedWithoutLosingTheFile() {
        let contents = """
        \(voice("2026-09-08T09:00:00", text: words(2)))
        {"ts": "2026-09-08T09:05:00", "text": "truncated
        {"ts": "2026-09-08T09:06:00", "source": "voice", "seconds": 5, "raw": "hi"}
        {"source": "voice", "seconds": 5, "raw": "hi", "text": "hi"}
        {"ts": "not a timestamp", "source": "voice", "seconds": 5, "raw": "hi", "text": "hi"}
        {"ts": null, "source": "voice", "seconds": 5, "raw": "hi", "text": "hi"}
        ["not", "an", "object"]

        \(voice("2026-09-08T09:10:00", text: words(3)))
        """
        let rows = HistoryParser.rows(from: contents, timeZone: Self.berlin)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.wordCount), [2, 3])
    }

    // MARK: - impossible rates

    /// The real history contains words delivered with `seconds` at zero, which divides to
    /// infinity. The row still counts toward the totals and is dropped from the rate.
    func testZeroSecondRowIsExcludedFromTheRateButKeptInTheTotals() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: words(100), seconds: 60))
        \(voice("2026-09-08T09:05:00", text: words(5), seconds: 0))
        """)

        XCTAssertEqual(insights.words, 105)
        XCTAssertEqual(insights.dictations, 2)
        XCTAssertEqual(insights.spokenDictations, 2)
        XCTAssertEqual(insights.spokenSeconds, 60)
        XCTAssertEqual(insights.spokenWordsPerMinute, 100, accuracy: 0.0001)
        XCTAssertTrue(insights.spokenWordsPerMinute.isFinite)
    }

    /// The ceiling is 400 words per minute. A row on the ceiling is real speech, a row past
    /// it is a bad duration.
    func testCeilingKeepsAPlausibleRowAndDropsAnImplausibleOne() {
        let onTheCeiling = compute(voice("2026-09-08T09:00:00", text: words(400), seconds: 60))
        XCTAssertEqual(onTheCeiling.spokenWordsPerMinute, 400, accuracy: 0.0001)

        let overTheCeiling = compute("""
        \(voice("2026-09-08T09:00:00", text: words(50), seconds: 60))
        \(voice("2026-09-08T09:05:00", text: words(402), seconds: 60))
        """)
        XCTAssertEqual(overTheCeiling.words, 452)
        XCTAssertEqual(overTheCeiling.spokenWordsPerMinute, 50, accuracy: 0.0001)
    }

    /// A duration below a quarter second cannot be told apart from a stopwatch that never
    /// started, so it is never a denominator even when the implied rate looks sane.
    func testDurationBelowTheFloorIsNeverADenominator() {
        let insights = compute(voice("2026-09-08T09:00:00", text: words(1), seconds: 0.2))
        XCTAssertEqual(insights.spokenWordsPerMinute, 0)
        XCTAssertEqual(insights.words, 1)
    }

    func testATypingRateOfZeroDoesNotDivideByZero() {
        let insights = compute(voice("2026-09-08T09:00:00", text: words(10), seconds: 60),
                               typing: 0)
        XCTAssertEqual(insights.minutesToType, 0)
        XCTAssertEqual(insights.typingWordsPerMinute, 0)
        XCTAssertEqual(insights.minutesSaved, -1, accuracy: 0.0001)
    }

    // MARK: - time saved

    func testMinutesSavedIsTypingTimeMinusSpeakingTime() {
        let insights = compute(voice("2026-09-08T09:00:00", text: words(200), seconds: 60),
                               typing: 40)
        XCTAssertEqual(insights.minutesToType, 5, accuracy: 0.0001)
        XCTAssertEqual(insights.minutesSpoken, 1, accuracy: 0.0001)
        XCTAssertEqual(insights.minutesSaved, 4, accuracy: 0.0001)
    }

    /// A typed FIX row is text somebody already typed. Crediting its words as typing avoided
    /// adds to one side of the subtraction with nothing on the other, which is how the hero
    /// figure came to be inflated by every text correction ever made.
    func testATypedRowContributesNoTypingTimeAvoided() {
        let spokenOnly = compute(voice("2026-09-08T09:00:00", text: words(120), seconds: 60),
                                 typing: 40)
        let withATypedRow = compute("""
        \(voice("2026-09-08T09:00:00", text: words(120), seconds: 60))
        \(typed("2026-09-08T10:00:00", text: words(400)))
        """, typing: 40)

        XCTAssertEqual(withATypedRow.words, 520)
        XCTAssertEqual(withATypedRow.spokenWords, 120)
        XCTAssertEqual(withATypedRow.minutesToType, spokenOnly.minutesToType, accuracy: 0.0001)
        XCTAssertEqual(withATypedRow.minutesSaved, spokenOnly.minutesSaved, accuracy: 0.0001)
        XCTAssertEqual(withATypedRow.minutesToType, 3, accuracy: 0.0001)
        XCTAssertEqual(withATypedRow.minutesSaved, 2, accuracy: 0.0001)
    }

    /// The exact shape the reviewer measured on real engine output, one voice row and one
    /// typed row, where the typed row pushed minutes to type above what was ever spoken.
    func testTypingTimeAvoidedIsOverSpokenWordsOnly() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: words(2), seconds: 3))
        \(typed("2026-09-08T09:01:00", text: words(4)))
        """, typing: 40)

        XCTAssertEqual(insights.spokenWords, 2)
        XCTAssertEqual(insights.minutesToType, 0.05, accuracy: 0.0001)
        XCTAssertEqual(insights.minutesSpoken, 0.05, accuracy: 0.0001)
        XCTAssertEqual(insights.minutesSaved, 0, accuracy: 0.0001)
    }

    /// Speaking two words over five minutes really is slower than typing them. The caller
    /// decides how to show that, so the number is never clamped here.
    func testMinutesSavedCanBeNegative() {
        let insights = compute(voice("2026-09-08T09:00:00", text: words(2), seconds: 300),
                               typing: 40)
        XCTAssertEqual(insights.minutesSaved, 0.05 - 5, accuracy: 0.0001)
        XCTAssertLessThan(insights.minutesSaved, 0)
    }

    // MARK: - latency

    /// Nearest-rank over ten spoken rows with total latencies 1 through 10.
    func testLatencyPercentilesAreNearestRank() {
        let lines = (1...10).map {
            voice("2026-09-08T09:0\($0 % 10):00", text: words(3), stt: 0, llm: Double($0))
        }
        let insights = compute(lines.joined(separator: "\n"))
        XCTAssertEqual(insights.latency.p50, 5)
        XCTAssertEqual(insights.latency.p90, 9)
        XCTAssertEqual(insights.latency.p99, 10)
    }

    func testLatencySumsBothStages() {
        let insights = compute(voice("2026-09-08T09:00:00", text: words(3), stt: 1.5, llm: 2.5))
        XCTAssertEqual(insights.latency.p50, 4, accuracy: 0.0001)
    }

    /// Slow means strictly over ten seconds, so a reply that lands exactly on ten is not slow.
    func testSlowCountIsStrictlyOverTenSeconds() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: words(3), stt: 0, llm: 9.5))
        \(voice("2026-09-08T09:01:00", text: words(3), stt: 0, llm: 10))
        \(voice("2026-09-08T09:02:00", text: words(3), stt: 0, llm: 10.5))
        """)
        XCTAssertEqual(insights.latency.slowCount, 1)
    }

    /// A typed row never waited on a microphone, so it does not belong in a speaking latency.
    func testLatencyIgnoresTypedRows() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: words(3), stt: 0, llm: 4))
        \(typed("2026-09-08T09:01:00", text: words(3), llm: 40))
        """)
        XCTAssertEqual(insights.latency.p99, 4)
        XCTAssertEqual(insights.latency.slowCount, 0)
    }

    // MARK: - the day window

    func testDaysIsAscendingExactlyAsLongAsAskedAndZeroFilled() {
        let insights = compute("""
        \(voice("2026-09-02T09:00:00", text: words(3)))
        \(voice("2026-09-08T09:00:00", text: words(4)))
        """, activityDays: 7)

        XCTAssertEqual(insights.days.count, 7)
        XCTAssertEqual(insights.days.first?.day, date("2026-09-02T00:00:00"))
        XCTAssertEqual(insights.days.last?.day, date("2026-09-08T00:00:00"))
        XCTAssertEqual(insights.days.map(\.count), [1, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(insights.days.map(\.words), [3, 0, 0, 0, 0, 0, 4])
    }

    func testTodayIsTheLastDay() {
        let insights = compute(voice("2026-09-08T09:00:00", text: words(4), seconds: 12))
        XCTAssertEqual(insights.today.day, insights.days.last?.day)
        XCTAssertEqual(insights.today.day, date("2026-09-08T00:00:00"))
        XCTAssertEqual(insights.today.count, 1)
        XCTAssertEqual(insights.today.words, 4)
        XCTAssertEqual(insights.today.spokenSeconds, 12)
    }

    /// A row older than the window still counts toward the totals, it simply has no bar.
    func testRowsOutsideTheWindowStillCountTowardTotals() {
        let insights = compute("""
        \(voice("2026-01-01T09:00:00", text: words(5)))
        \(voice("2026-09-08T09:00:00", text: words(2)))
        """, activityDays: 7)
        XCTAssertEqual(insights.days.map(\.count), [0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(insights.dictations, 2)
        XCTAssertEqual(insights.words, 7)
    }

    /// A typed day has a count and words but no speaking seconds.
    func testDaySummaryExcludesTypedSecondsFromSpeakingTime() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: words(3), seconds: 20))
        \(typed("2026-09-08T10:00:00", text: words(7)))
        """)
        XCTAssertEqual(insights.today.count, 2)
        XCTAssertEqual(insights.today.words, 10)
        XCTAssertEqual(insights.today.spokenSeconds, 20)
    }

    // MARK: - streaks

    func testStreakEndingTodayCounts() {
        let insights = compute("""
        \(voice("2026-09-06T09:00:00", text: "hi"))
        \(voice("2026-09-07T09:00:00", text: "hi"))
        \(voice("2026-09-08T09:00:00", text: "hi"))
        """)
        XCTAssertEqual(insights.currentStreak, 3)
        XCTAssertEqual(insights.bestStreak, 3)
    }

    /// A day that has only just started is not evidence the speaker stopped, so a run ending
    /// yesterday is still the current streak.
    func testStreakEndingYesterdayStillCounts() {
        let insights = compute("""
        \(voice("2026-09-06T09:00:00", text: "hi"))
        \(voice("2026-09-07T09:00:00", text: "hi"))
        """)
        XCTAssertEqual(insights.currentStreak, 2)
    }

    func testStreakOlderThanYesterdayIsBroken() {
        let insights = compute("""
        \(voice("2026-09-05T09:00:00", text: "hi"))
        \(voice("2026-09-06T09:00:00", text: "hi"))
        """)
        XCTAssertEqual(insights.currentStreak, 0)
        XCTAssertEqual(insights.bestStreak, 2)
    }

    /// A streak must step by calendar days, so the 25 hour day cannot break it.
    func testStreakStepsAcrossTheClockChange() {
        let insights = compute("""
        \(voice("2026-10-24T09:00:00", text: "hi"))
        \(voice("2026-10-25T09:00:00", text: "hi"))
        \(voice("2026-10-26T09:00:00", text: "hi"))
        """, now: "2026-10-26T12:00:00")
        XCTAssertEqual(insights.currentStreak, 3)
    }

    func testBestStreakIsTheLongestRunAndCanExceedTheWindow() {
        let insights = compute("""
        \(voice("2026-08-01T09:00:00", text: "hi"))
        \(voice("2026-08-02T09:00:00", text: "hi"))
        \(voice("2026-08-03T09:00:00", text: "hi"))
        \(voice("2026-08-04T09:00:00", text: "hi"))
        \(voice("2026-08-05T09:00:00", text: "hi"))
        \(voice("2026-08-06T09:00:00", text: "hi"))
        \(voice("2026-08-07T09:00:00", text: "hi"))
        \(voice("2026-08-08T09:00:00", text: "hi"))
        \(voice("2026-09-08T09:00:00", text: "hi"))
        """, activityDays: 3)
        XCTAssertEqual(insights.days.count, 3)
        XCTAssertEqual(insights.bestStreak, 8)
        XCTAssertEqual(insights.currentStreak, 1)
    }

    func testRepeatedDictationsOnOneDayAreOneStreakDay() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: "hi"))
        \(voice("2026-09-08T10:00:00", text: "hi"))
        \(voice("2026-09-08T11:00:00", text: "hi"))
        """)
        XCTAssertEqual(insights.currentStreak, 1)
        XCTAssertEqual(insights.bestStreak, 1)
    }

    // MARK: - counts and flags

    func testGuardedTrimmedAndFlaggedCounts() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: "hi", guarded: true, trimmed: false))
        \(voice("2026-09-08T09:01:00", text: "hi", guarded: false, trimmed: true))
        \(voice("2026-09-08T09:02:00", text: "hi", guarded: true, trimmed: true))
        {"ts": "2026-09-08T09:03:00", "source": "voice", "seconds": 5, "raw": "hi", \
        "text": "hi", "flagged": true}
        """)
        XCTAssertEqual(insights.guardedCount, 2)
        XCTAssertEqual(insights.trimmedCount, 2)
        XCTAssertEqual(insights.flaggedCount, 1)
    }

    // MARK: - per model

    /// Every row written before this release carries no model identity. Those rows are
    /// skipped rather than pooled under an invented name.
    func testPerModelSkipsRowsWithNoModelAndSortsByCountDescending() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: "hi", stt: 0, llm: 1, llmModel: "qwen"))
        \(voice("2026-09-08T09:01:00", text: "hi", stt: 0, llm: 3, llmModel: "qwen"))
        \(voice("2026-09-08T09:02:00", text: "hi", stt: 0, llm: 5, llmModel: "qwen", guarded: true))
        \(voice("2026-09-08T09:03:00", text: "hi", stt: 0, llm: 2, llmModel: "gemma"))
        \(voice("2026-09-08T09:04:00", text: "hi"))
        """)

        XCTAssertEqual(insights.perModel.count, 2)
        XCTAssertEqual(insights.perModel[0].llmModel, "qwen")
        XCTAssertEqual(insights.perModel[0].count, 3)
        XCTAssertEqual(insights.perModel[0].medianLatency, 3, accuracy: 0.0001)
        XCTAssertEqual(insights.perModel[0].guardedCount, 1)
        XCTAssertEqual(insights.perModel[1].llmModel, "gemma")
        XCTAssertEqual(insights.perModel[1].count, 1)
    }

    /// The engine writes `llm_model` on cloud rows too, the configured local model, whether
    /// or not that model did the correcting. Billing the cloud's work to the idle local model
    /// is what made this pane's counts wrong.
    func testPerModelAttributesACloudRowToTheModelThatAnswered() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: "hi", stt: 0, llm: 1, llmModel: "qwen"))
        \(voice("2026-09-08T09:01:00", text: "hi", stt: 0, llm: 3, backend: "claude",
                     mode: "cloud", llmModel: "qwen", cloudModel: "claude-sonnet-5"))
        """)

        XCTAssertEqual(insights.perModel.count, 2)
        XCTAssertEqual(Set(insights.perModel.map(\.llmModel)), ["qwen", "claude-sonnet-5"])
        XCTAssertEqual(insights.perModel.first { $0.llmModel == "qwen" }?.count, 1)
        XCTAssertEqual(insights.perModel.first { $0.llmModel == "claude-sonnet-5" }?.count, 1)
    }

    /// A cloud request the cloud never served falls back to the local model, and the local
    /// model is then the one that did the correcting.
    func testPerModelCountsARefusedCloudRowAgainstTheLocalModel() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: "hi", stt: 0, llm: 2, mode: "cloud",
                     llmModel: "qwen", cloudModel: "claude-sonnet-5"))
        """)

        XCTAssertEqual(insights.perModel.map(\.llmModel), ["qwen"])
    }

    /// The pane presents this as a correction model's latency, so speech time has no business
    /// in it. Both rows below take 9 seconds in all and 2 seconds of correction.
    func testPerModelLatencyIsCorrectionTimeAlone() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: "hi", stt: 7, llm: 2, llmModel: "qwen"))
        \(voice("2026-09-08T09:01:00", text: "hi", stt: 7, llm: 2, llmModel: "qwen"))
        """)

        XCTAssertEqual(insights.perModel[0].medianLatency, 2, accuracy: 0.0001)
    }

    func testPerModelBreaksATieOnNameSoTheOrderIsStable() {
        let insights = compute("""
        \(voice("2026-09-08T09:00:00", text: "hi", llmModel: "zephyr"))
        \(voice("2026-09-08T09:01:00", text: "hi", llmModel: "alpaca"))
        """)
        XCTAssertEqual(insights.perModel.map(\.llmModel), ["alpaca", "zephyr"])
    }

    // MARK: - nothing at all

    func testEmptyRowsComputeToAValidAllZeroResult() {
        let insights = Insights.compute(rows: [],
                                        typingWordsPerMinute: 40,
                                        calendar: berlinCalendar(),
                                        now: date("2026-09-08T12:00:00"),
                                        activityDays: 7)

        XCTAssertEqual(insights.dictations, 0)
        XCTAssertEqual(insights.spokenDictations, 0)
        XCTAssertEqual(insights.words, 0)
        XCTAssertEqual(insights.spokenSeconds, 0)
        XCTAssertEqual(insights.minutesToType, 0)
        XCTAssertEqual(insights.minutesSpoken, 0)
        XCTAssertEqual(insights.minutesSaved, 0)
        XCTAssertEqual(insights.spokenWordsPerMinute, 0)
        XCTAssertEqual(insights.currentStreak, 0)
        XCTAssertEqual(insights.bestStreak, 0)
        XCTAssertEqual(insights.guardedCount, 0)
        XCTAssertEqual(insights.trimmedCount, 0)
        XCTAssertEqual(insights.flaggedCount, 0)
        XCTAssertEqual(insights.routeCounts, [.local: 0, .cloud: 0])
        XCTAssertEqual(insights.latency, Insights.Latency(p50: 0, p90: 0, p99: 0, slowCount: 0))
        XCTAssertTrue(insights.perModel.isEmpty)
        XCTAssertEqual(insights.days.count, 7)
        XCTAssertEqual(insights.days.map(\.count), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(insights.today.day, date("2026-09-08T00:00:00"))
        XCTAssertEqual(insights.today.count, 0)
    }

    /// `today` is defined as the last element, so a nonsensical span still has one.
    func testAZeroDaySpanStillHasAToday() {
        let insights = compute("", activityDays: 0)
        XCTAssertEqual(insights.days.count, 1)
        XCTAssertEqual(insights.today.day, date("2026-09-08T00:00:00"))
    }

    // MARK: - archives

    /// The engine keeps every archive as `history.jsonl.<n>` with `.1` the oldest. As strings
    /// `.10` sorts between `.1` and `.2`, which silently reorders a decade of history.
    func testArchivePathsSortNumericallyAndEndWithTheLiveFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phona-insights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        for name in ["history.jsonl", "history.jsonl.1", "history.jsonl.2", "history.jsonl.9",
                     "history.jsonl.10", "history.jsonl.11", "corrections.jsonl",
                     "history.jsonl.gz", "history.jsonl.bak", "phonad.log"] {
            try Data().write(to: base.appendingPathComponent(name))
        }

        XCTAssertEqual(HistoryParser.archivePaths(base: base).map(\.lastPathComponent),
                       ["history.jsonl.1", "history.jsonl.2", "history.jsonl.9",
                        "history.jsonl.10", "history.jsonl.11", "history.jsonl"])
    }

    func testArchivePathsReturnWhatExists() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phona-insights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try Data().write(to: base.appendingPathComponent("history.jsonl.3"))
        XCTAssertEqual(HistoryParser.archivePaths(base: base).map(\.lastPathComponent),
                       ["history.jsonl.3"])
    }

    func testArchivePathsOnAMissingDirectoryIsEmpty() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phona-absent-\(UUID().uuidString)")
        XCTAssertTrue(HistoryParser.archivePaths(base: base).isEmpty)
    }
}
