import Foundation

/// One calendar day of activity, with `day` the start of that day in the caller's calendar.
public struct DaySummary: Sendable, Equatable {
    public let day: Date
    public let count: Int
    public let words: Int
    public let spokenSeconds: Double

    public init(day: Date, count: Int, words: Int, spokenSeconds: Double) {
        self.day = day
        self.count = count
        self.words = words
        self.spokenSeconds = spokenSeconds
    }
}

/// Everything the window shows about a history file, computed once.
///
/// The whole value of this type is that every number in it survives a real history file.
/// That file contains rows with no model identity, rows nobody spoke, rows whose duration is
/// physically impossible, and rows that are not valid JSON. Each field below states which of
/// those it counts and which it refuses, because the same figure can be wrong several ways.
public struct Insights: Sendable {
    public let dictations: Int
    public let spokenDictations: Int
    public let words: Int
    public let spokenWords: Int
    public let spokenSeconds: Double
    public let typingWordsPerMinute: Double
    /// Over `spokenWords`, never `words`. A typed FIX row is text somebody already typed, so
    /// crediting its words as typing avoided adds a figure with nothing on the other side of
    /// the subtraction and inflates every hour the hero claims.
    public let minutesToType: Double
    public let minutesSpoken: Double
    public let minutesSaved: Double
    public let spokenWordsPerMinute: Double
    public let today: DaySummary
    public let days: [DaySummary]
    public let currentStreak: Int
    public let bestStreak: Int
    public let routeCounts: [Route: Int]
    public let guardedCount: Int
    public let trimmedCount: Int
    public let flaggedCount: Int
    public let latency: Latency
    public let perModel: [ModelUsage]

    public struct Latency: Sendable, Equatable {
        public let p50: Double
        public let p90: Double
        public let p99: Double
        public let slowCount: Int

        public init(p50: Double, p90: Double, p99: Double, slowCount: Int) {
            self.p50 = p50
            self.p90 = p90
            self.p99 = p99
            self.slowCount = slowCount
        }
    }

    public struct ModelUsage: Sendable, Equatable {
        public let llmModel: String
        public let count: Int
        public let medianLatency: Double
        public let guardedCount: Int

        public init(llmModel: String, count: Int, medianLatency: Double, guardedCount: Int) {
            self.llmModel = llmModel
            self.count = count
            self.medianLatency = medianLatency
            self.guardedCount = guardedCount
        }
    }

    /// A speaking rate above this is not speech, it is a bad duration. The fastest speech
    /// ever recorded is near 640 words per minute and ordinary dictation runs 110 to 150, so
    /// a row implying more than this is dropped from every rate while still counting toward
    /// the totals.
    public static let maxPlausibleWordsPerMinute: Double = 400

    /// Below this a duration cannot be told apart from a stopwatch that never started, so it
    /// is never allowed to be a denominator. The real history contains words delivered with
    /// `seconds` at zero, which divides to infinity.
    public static let minimumRateSeconds: Double = 0.25

    /// The point past which a speaker notices they are waiting for the reply.
    public static let slowSeconds: Double = 10

    public init(dictations: Int,
                spokenDictations: Int,
                words: Int,
                spokenWords: Int,
                spokenSeconds: Double,
                typingWordsPerMinute: Double,
                minutesToType: Double,
                minutesSpoken: Double,
                minutesSaved: Double,
                spokenWordsPerMinute: Double,
                today: DaySummary,
                days: [DaySummary],
                currentStreak: Int,
                bestStreak: Int,
                routeCounts: [Route: Int],
                guardedCount: Int,
                trimmedCount: Int,
                flaggedCount: Int,
                latency: Latency,
                perModel: [ModelUsage]) {
        self.dictations = dictations
        self.spokenDictations = spokenDictations
        self.words = words
        self.spokenWords = spokenWords
        self.spokenSeconds = spokenSeconds
        self.typingWordsPerMinute = typingWordsPerMinute
        self.minutesToType = minutesToType
        self.minutesSpoken = minutesSpoken
        self.minutesSaved = minutesSaved
        self.spokenWordsPerMinute = spokenWordsPerMinute
        self.today = today
        self.days = days
        self.currentStreak = currentStreak
        self.bestStreak = bestStreak
        self.routeCounts = routeCounts
        self.guardedCount = guardedCount
        self.trimmedCount = trimmedCount
        self.flaggedCount = flaggedCount
        self.latency = latency
        self.perModel = perModel
    }

    /// Every day figure comes from `calendar`, never from dividing by 86400.
    ///
    /// Europe/Berlin has a 25 hour day on 25 October 2026, so arithmetic on seconds puts
    /// dictations on the wrong day and silently breaks a streak. `calendar` must carry the
    /// same time zone the rows were parsed in, otherwise the buckets and the timestamps
    /// disagree. An empty `rows` array is valid input and yields a valid all-zero result.
    public static func compute(rows: [HistoryRow],
                               typingWordsPerMinute: Double,
                               calendar: Calendar,
                               now: Date,
                               activityDays: Int) -> Insights {
        let typingRate = typingWordsPerMinute.isFinite && typingWordsPerMinute > 0
            ? typingWordsPerMinute
            : 0

        let spoken = rows.filter { $0.isSpoken }
        let words = rows.reduce(0) { $0 + $1.wordCount }
        let spokenWords = spoken.reduce(0) { $0 + $1.wordCount }
        let spokenSeconds = spoken.reduce(0.0) { $0 + max($1.seconds, 0) }

        let minutesToType = typingRate > 0 ? Double(spokenWords) / typingRate : 0
        let minutesSpoken = spokenSeconds / 60

        var routeCounts: [Route: Int] = [.local: 0, .cloud: 0]
        for row in rows {
            routeCounts[row.route, default: 0] += 1
        }

        let buckets = dayBuckets(rows: rows, calendar: calendar)
        let days = window(buckets: buckets, calendar: calendar, now: now, activityDays: activityDays)
        let today = days.last
            ?? DaySummary(day: calendar.startOfDay(for: now), count: 0, words: 0, spokenSeconds: 0)

        let active = Set(buckets.keys)
        let latencies = spoken.map { $0.sttSecs + $0.llmSecs }.sorted()

        return Insights(dictations: rows.count,
                        spokenDictations: spoken.count,
                        words: words,
                        spokenWords: spokenWords,
                        spokenSeconds: spokenSeconds,
                        typingWordsPerMinute: typingRate,
                        minutesToType: minutesToType,
                        minutesSpoken: minutesSpoken,
                        minutesSaved: minutesToType - minutesSpoken,
                        spokenWordsPerMinute: spokenRate(spoken),
                        today: today,
                        days: days,
                        currentStreak: currentStreak(active: active, calendar: calendar, now: now),
                        bestStreak: bestStreak(active: active, calendar: calendar),
                        routeCounts: routeCounts,
                        guardedCount: rows.filter { $0.guarded }.count,
                        trimmedCount: rows.filter { $0.trimmed }.count,
                        flaggedCount: rows.filter { $0.flagged }.count,
                        latency: Latency(p50: percentile(latencies, 50),
                                         p90: percentile(latencies, 90),
                                         p99: percentile(latencies, 99),
                                         slowCount: latencies.filter { $0 > slowSeconds }.count),
                        perModel: perModel(rows: rows))
    }

    /// Nearest-rank, over an already ascending sample. The rank is `ceil(p/100 * n)` and the
    /// value at that rank is returned as it is, with no interpolation, so every percentile is
    /// a duration that actually happened.
    public static func percentile(_ ascending: [Double], _ p: Double) -> Double {
        guard !ascending.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(ascending.count)).rounded(.up))
        return ascending[min(max(rank - 1, 0), ascending.count - 1)]
    }

    private static func dayBuckets(rows: [HistoryRow],
                                   calendar: Calendar) -> [Date: DaySummary] {
        var buckets: [Date: DaySummary] = [:]
        for row in rows {
            let key = calendar.startOfDay(for: row.ts)
            let previous = buckets[key]
            buckets[key] = DaySummary(day: key,
                                      count: (previous?.count ?? 0) + 1,
                                      words: (previous?.words ?? 0) + row.wordCount,
                                      spokenSeconds: (previous?.spokenSeconds ?? 0)
                                          + (row.isSpoken ? max(row.seconds, 0) : 0))
        }
        return buckets
    }

    /// Ascending, `activityDays` long, ending on today, with days nobody dictated on present
    /// as zero entries so a chart has no holes in it. A span below one is raised to one,
    /// because `today` is defined as the last element and there has to be one.
    private static func window(buckets: [Date: DaySummary],
                               calendar: Calendar,
                               now: Date,
                               activityDays: Int) -> [DaySummary] {
        let span = max(activityDays, 1)
        var descending: [DaySummary] = []
        var cursor = calendar.startOfDay(for: now)
        for _ in 0..<span {
            descending.append(buckets[cursor]
                ?? DaySummary(day: cursor, count: 0, words: 0, spokenSeconds: 0))
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return descending.reversed()
    }

    /// A rate over the rows that can carry one. A row whose implied speed is impossible is
    /// left out of both halves of the fraction, so one bad duration cannot drag the figure.
    private static func spokenRate(_ spoken: [HistoryRow]) -> Double {
        var words = 0
        var seconds = 0.0
        for row in spoken {
            guard row.seconds >= minimumRateSeconds else { continue }
            let implied = Double(row.wordCount) / (row.seconds / 60)
            guard implied.isFinite, implied <= maxPlausibleWordsPerMinute else { continue }
            words += row.wordCount
            seconds += row.seconds
        }
        guard seconds >= minimumRateSeconds else { return 0 }
        return Double(words) / (seconds / 60)
    }

    /// Consecutive days with at least one dictation, anchored on today when today has one and
    /// on yesterday otherwise. Yesterday is the anchor for the edge case, because a day that
    /// has only just started is not evidence the speaker stopped.
    private static func currentStreak(active: Set<Date>, calendar: Calendar, now: Date) -> Int {
        let today = calendar.startOfDay(for: now)
        var anchor: Date?
        if active.contains(today) {
            anchor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  active.contains(yesterday) {
            anchor = yesterday
        }
        guard var cursor = anchor else { return 0 }
        var streak = 0
        while active.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// The longest run anywhere in the history, not only inside the `days` window, so a run
    /// longer than the window cannot be reported as shorter than the current one.
    private static func bestStreak(active: Set<Date>, calendar: Calendar) -> Int {
        let ordered = active.sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for day in ordered {
            if let last = previous,
               calendar.dateComponents([.day], from: last, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// Grouped by the model that actually did the correcting, which is not always `llmModel`.
    ///
    /// The engine writes `llm_model` on every row, the configured local model, whether or not
    /// that model was the one asked. On a row the cloud answered, `cloud_model` is the model
    /// that did the work and the local one did nothing, so grouping on `llmModel` alone bills
    /// the cloud's usage to the grammar model sitting idle. A row that names neither is
    /// skipped rather than pooled under an invented name.
    ///
    /// Typed FIX rows belong here as much as spoken ones, because the grammar model answers
    /// both. What does not belong is their speech time: the latency below is `llmSecs` alone,
    /// so a figure this pane presents as a correction model's speed is only correction.
    private static func perModel(rows: [HistoryRow]) -> [ModelUsage] {
        var groups: [String: [HistoryRow]] = [:]
        for row in rows {
            guard let model = correctingModel(row) else { continue }
            groups[model, default: []].append(row)
        }
        return groups.map { model, group in
            ModelUsage(llmModel: model,
                       count: group.count,
                       medianLatency: percentile(group.map { $0.llmSecs }.sorted(), 50),
                       guardedCount: group.filter { $0.guarded }.count)
        }
        .sorted { $0.count == $1.count ? $0.llmModel < $1.llmModel : $0.count > $1.count }
    }

    /// The cloud model when the cloud answered, the local one otherwise. A cloud request that
    /// fell back to the local model has no backend and so is a local correction here, which
    /// is the same reading `route` and the History detail pane take.
    private static func correctingModel(_ row: HistoryRow) -> String? {
        row.route == .cloud ? row.cloudModel : row.llmModel
    }
}
