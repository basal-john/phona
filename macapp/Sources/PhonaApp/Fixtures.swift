import Foundation
import PhonaCore

/// A history that exercises every shape the window can draw, for offscreen rendering.
///
/// Built rather than read, because `phona --render` has to produce the same images on a
/// machine that has never dictated as it does on one with a year of history behind it. The
/// rows carry a guard rejection, a trim, a flag, a slow pair of stages, a cloud row whose
/// reply was thrown away and a typed FIX row, so no pane renders its empty state by
/// accident and none of the notes go unseen.
enum Fixtures {
    /// Dates are relative to a fixed instant rather than to now, so two renders a day apart
    /// produce byte-identical images and a diff means a design change.
    static let now = Date(timeIntervalSince1970: 1_757_000_000)

    static let localModel = "mlx-community/Qwen3-4B-Instruct-2507-8bit"
    static let speechModel = "mlx-community/parakeet-tdt-0.6b-v3"
    static let cloudModel = "claude-sonnet-4-5"

    private static let samples: [(heard: String, delivered: String)] = [
        ("there any way we can access these logs from the preference menu",
         "Is there any way we can access these logs from the preference menu?"),
        ("we didn't found the root cause yet but we are investigating it since monday",
         "We haven't found the root cause yet, but we have been investigating it since Monday."),
        ("i will take a look at the failing pipeline after standup",
         "I will take a look at the failing pipeline after standup."),
        ("can you rerun the visual suite once the snapshot is regenerated",
         "Can you rerun the visual suite once the snapshot is regenerated?"),
        ("the ticket is ready for review but the description still needs the repro steps",
         "The ticket is ready for review, but the description still needs the repro steps."),
        ("lets move the sync to thursday so everyone in the other timezone can join",
         "Let's move the sync to Thursday so everyone in the other time zone can join."),
    ]

    /// One row per entry, spread back over the activity window so the chart has a shape.
    ///
    /// Oldest first, which is the order `history.jsonl` is written in and therefore the
    /// order the app is entitled to assume. `HistoryOrder.newestFirst` reverses file
    /// position rather than sorting by timestamp, deliberately, because the engine stamps
    /// to the whole second and a sort would tie. A fixture built newest-first came back out
    /// of that reversal upside down, which is a bug in the fixture and not in the ordering.
    static func rows() -> [HistoryRow] {
        var rows: [HistoryRow] = []
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)

        for offset in (0..<HistoryStore.activityDays).reversed() {
            // A gap and a peak, so the chart is neither flat nor uniformly full.
            let perDay: Int
            switch offset {
            case 0: perDay = 4
            case 1: perDay = 6
            case 4, 5, 12, 13, 19, 26, 27: perDay = 0
            case 8: perDay = 9
            default: perDay = offset % 3 + 1
            }
            guard perDay > 0 else { continue }

            for index in (0..<perDay).reversed() {
                let sample = samples[(offset + index) % samples.count]
                let stamp = calendar.date(byAdding: .second,
                                          value: -(offset * 86_400) - index * 1_800 - 34_000,
                                          to: day) ?? now
                let sequence = offset * 10 + index
                let isCloud = sequence % 7 == 3
                let refusedCloud = sequence % 21 == 3
                /// Above `Insights.slowSeconds`, which is 10, so the pane's slow chip and
                /// its slow note actually appear. The first version of this fixture used
                /// 7.5 s in total and read as slow to nobody but its author.
                let isSlow = sequence % 13 == 0
                let isTyped = sequence % 29 == 11

                rows.append(HistoryRow(
                    ts: stamp,
                    source: isTyped ? "fix" : "voice",
                    mode: isCloud ? "cloud" : "local",
                    backend: isCloud && !refusedCloud ? "claude" : nil,
                    sttModel: speechModel,
                    llmModel: localModel,
                    cloudModel: isCloud ? cloudModel : nil,
                    style: nil,
                    raw: isTyped ? "" : sample.heard,
                    text: sample.delivered,
                    seconds: isTyped ? 0 : Double(sample.heard.count) / 14.0,
                    sttSecs: isSlow ? 7.4 : 0.72,
                    llmSecs: isSlow ? 5.2 : 0.41,
                    guarded: sequence % 11 == 5,
                    guardReason: sequence % 11 == 5
                        ? (isCloud ? "cloud claude: reply added a sentence" : "reply added a sentence")
                        : nil,
                    trimmed: sequence % 17 == 9,
                    audio: nil,
                    cloudSent: isCloud))
            }
        }
        return rows
    }

    static let dictionary = [
        "Parakeet", "Phona", "Qwen", "Thomann", "Drone", "Detox", "Playwright",
        "MLX", "Stremio", "Caddy", "Prowlarr", "AIOStreams", "Erlangen", "Jira",
        "Copilot", "Xcode", "TestFlight", "Sonoma", "Tahoe",
    ]

    static let replacements = [
        "phone a": "Phona",
        "para keet": "Parakeet",
        "thomann's": "Thomann's",
        "jeera": "Jira",
    ]

    /// The newest row carries a flag, because the detail pane only offers the button there
    /// and the "what you actually said" block only renders when a flag exists.
    static func snapshot() -> HistorySnapshot {
        let rows = rows()
        let rate = HistoryStore.defaultTypingWordsPerMinute
        var snapshot = HistorySnapshot.empty(typingWordsPerMinute: rate, now: now)
        snapshot.rows = rows
        snapshot.insights = Insights.compute(rows: rows,
                                             typingWordsPerMinute: rate,
                                             calendar: .current,
                                             now: now,
                                             activityDays: HistoryStore.activityDays)
        if let newest = HistoryOrder.newestFirst(rows).first {
            snapshot.corrections = [
                CorrectionLog.key(for: newest): Correction(
                    flaggedAt: newest.ts,
                    actual: "Is there any way we can reach these logs from the Preferences menu?"),
            ]
            snapshot.flaggedRowCount = 1
        }
        snapshot.dictionary = dictionary
        snapshot.replacements = replacements
        snapshot.sttModel = speechModel
        snapshot.llmModel = localModel
        snapshot.cloudModel = cloudModel
        return snapshot
    }
}
