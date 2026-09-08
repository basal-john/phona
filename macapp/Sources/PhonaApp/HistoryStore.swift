import Foundation
import PhonaCore
import SwiftUI

/// Everything the window reads off disk, gathered in one background pass.
///
/// One value rather than several published properties, because the panes cross-reference
/// each other. A half-applied load would show a row count from the new history against a
/// dictionary count from the old config, and a reader has no way to tell that happened.
struct HistorySnapshot: Sendable {
    var rows: [HistoryRow] = []
    var insights: Insights
    var corrections: [CorrectionKey: Correction] = [:]

    /// Rows a flag actually joins, counted once during the load.
    ///
    /// Not `corrections.count`. That is records in the file, and a record whose transcript
    /// matches no row on disk joins nothing, so the two can disagree and the filter shows the
    /// join. Counted here rather than in the picker because the picker asks on every render
    /// and the walk is over every row in every archive.
    var flaggedRowCount = 0
    var dictionary: [String] = []
    var replacements: [String: String] = [:]
    var typingWordsPerMinute: Double = HistoryStore.defaultTypingWordsPerMinute
    var useInitialPrompt = false
    var sttModel: String?
    var llmModel: String?
    var cloudModel: String?

    static func empty(typingWordsPerMinute: Double = HistoryStore.defaultTypingWordsPerMinute,
                      now: Date = Date()) -> HistorySnapshot {
        HistorySnapshot(insights: Insights.compute(rows: [],
                                                   typingWordsPerMinute: typingWordsPerMinute,
                                                   calendar: .current,
                                                   now: now,
                                                   activityDays: HistoryStore.activityDays),
                        typingWordsPerMinute: typingWordsPerMinute)
    }
}

/// Loads the whole history for the window, off the main thread, every time.
///
/// `HistoryEntry.recent()` reads the live file into one String and keeps the last twelve
/// lines, which is right for a menu and wrong here: the window groups by day, counts routes
/// and computes a streak, all of which need every row including the archives. The live file
/// is already about a megabyte and only grows, so the read never happens on the main thread.
///
/// Reloading is driven by the window becoming key rather than by a timer. A timer would
/// re-read a megabyte on a schedule nobody asked for, and the only moment a stale figure
/// matters is the moment someone looks at it.
final class HistoryStore: ObservableObject {
    /// Long enough that a chart shows a month plus the run-up to it, short enough that each
    /// of the 37 bars stays wide enough to aim a cursor at inside a 900pt window.
    static let activityDays = 37

    /// A middling sustained typing speed, used until the speaker says otherwise. It is only
    /// ever a divisor in a figure that is shown with its own arithmetic underneath, so a
    /// reader who types faster can see exactly which number to distrust.
    static let defaultTypingWordsPerMinute: Double = 45

    static let typingSpeedKey = "typing_wpm"

    @Published private(set) var snapshot = HistorySnapshot.empty()
    @Published private(set) var isLoading = false

    /// Set when a load found no readable history file at all, which is different from a
    /// history file with nothing in it and reads differently in an empty state.
    @Published private(set) var hasHistoryFile = true

    private let queue = DispatchQueue(label: "com.basalona.phona.history", qos: .userInitiated)
    private var loadGeneration = 0
    private var rateGeneration = 0

    var rows: [HistoryRow] { snapshot.rows }
    var insights: Insights { snapshot.insights }

    /// Newest first, which is the order every list in the window shows. Ordered by
    /// `HistoryOrder`, off the main thread with the rest of the load.
    @Published private(set) var descending: [HistoryRow] = []

    /// Bumped every time a load lands. A view holding an index into `descending` watches this
    /// to know the array underneath it was replaced.
    @Published private(set) var loadToken = 0

    /// Reads, parses, orders and computes on `queue`, and touches the main thread only to
    /// publish the finished value.
    ///
    /// Every one of those steps grows with the archive set, which only ever gets bigger, and
    /// the compute alone was measured at 3.2 seconds over 41 MB. None of it belongs on the
    /// thread that has to keep drawing the window.
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        queue.async { [weak self] in
            let loaded = HistoryStore.read()
            let descending = HistoryOrder.newestFirst(loaded.snapshot.rows)
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.snapshot = loaded.snapshot
                self.descending = descending
                self.hasHistoryFile = loaded.hasHistoryFile
                self.isLoading = false
                self.loadToken += 1
            }
        }
    }

    /// Persist a new typing speed and recompute, without re-reading a megabyte of history.
    ///
    /// The rate is only ever a divisor over rows already in hand, so a change to it is
    /// arithmetic rather than a load. The arithmetic still walks every row, so it runs on
    /// `queue` like the load does. Written with `Settings.set`, which rewrites one key and
    /// leaves the rest of config.json alone, because the daemon reads that same file.
    ///
    /// A reload that lands first wins, because it recomputes from the config this just wrote.
    func setTypingWordsPerMinute(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        Settings.set(HistoryStore.typingSpeedKey, rate)
        rateGeneration += 1
        let rateToken = rateGeneration
        let loadToken = loadGeneration
        let rows = snapshot.rows
        snapshot.typingWordsPerMinute = rate
        queue.async { [weak self] in
            let insights = Insights.compute(rows: rows,
                                            typingWordsPerMinute: rate,
                                            calendar: .current,
                                            now: Date(),
                                            activityDays: HistoryStore.activityDays)
            DispatchQueue.main.async {
                guard let self,
                      rateToken == self.rateGeneration,
                      loadToken == self.loadGeneration else { return }
                var updated = self.snapshot
                updated.typingWordsPerMinute = rate
                updated.insights = insights
                self.snapshot = updated
            }
        }
    }

    /// The flag on a row, when the speaker raised one.
    func correction(for row: HistoryRow) -> Correction? {
        snapshot.corrections[CorrectionLog.key(for: row)]
    }

    func isFlagged(_ row: HistoryRow) -> Bool {
        correction(for: row) != nil
    }

    /// Whether the daemon's FLAG command can act on this row.
    ///
    /// FLAG reads the last line of history.jsonl and flags that, with no way to name a row,
    /// so it is honest only for the newest one. Offering the button on an older row would
    /// flag a dictation the speaker was not looking at.
    func canFlag(_ row: HistoryRow) -> Bool {
        descending.first == row
    }

    private static func read() -> (snapshot: HistorySnapshot, hasHistoryFile: Bool) {
        let zone = TimeZone.current
        let paths = HistoryParser.archivePaths(base: Paths.base)
        var rows: [HistoryRow] = []
        for url in paths {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            rows.append(contentsOf: HistoryParser.rows(from: contents, timeZone: zone))
        }

        let config = readConfig()
        let rate = typingRate(from: config)
        var snapshot = HistorySnapshot.empty(typingWordsPerMinute: rate)
        snapshot.rows = rows
        snapshot.insights = Insights.compute(rows: rows,
                                             typingWordsPerMinute: rate,
                                             calendar: .current,
                                             now: Date(),
                                             activityDays: activityDays)
        snapshot.corrections = readCorrections(timeZone: zone)
        snapshot.flaggedRowCount = rows.reduce(into: 0) { total, row in
            if snapshot.corrections[CorrectionLog.key(for: row)] != nil { total += 1 }
        }
        snapshot.dictionary = (config["dictionary"] as? [String]) ?? []
        snapshot.replacements = (config["replacements"] as? [String: String]) ?? [:]
        snapshot.useInitialPrompt = (config["use_initial_prompt"] as? NSNumber)?.boolValue ?? false
        snapshot.sttModel = nonEmpty(config["stt_model"])
        snapshot.llmModel = nonEmpty(config["llm_model"])
        snapshot.cloudModel = nonEmpty(config["cloud_model"])
        return (snapshot, !paths.isEmpty)
    }

    /// `corrections.jsonl`, indexed by `CorrectionLog` so a flag lands on one dictation.
    ///
    /// The flag does not live on the history row. `Insights.flaggedCount` reads an optional
    /// `flagged` key that the engine never writes, so it is always zero, and the real record
    /// is this separate append-only file. The join is what makes the flagged filter and the
    /// detail pane's ground truth possible at all.
    private static func readCorrections(timeZone: TimeZone) -> [CorrectionKey: Correction] {
        let url = Paths.base.appendingPathComponent("corrections.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return CorrectionLog.flags(from: contents, timeZone: timeZone)
    }

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// A speed of zero or a nonsense one turns the hero figure into a claim of infinite time
    /// saved, so anything outside a range a human can sustain falls back to the default.
    private static func typingRate(from config: [String: Any]) -> Double {
        guard let raw = config[typingSpeedKey] as? NSNumber else {
            return defaultTypingWordsPerMinute
        }
        let rate = raw.doubleValue
        guard rate.isFinite, rate >= 5, rate <= 200 else { return defaultTypingWordsPerMinute }
        return rate
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
