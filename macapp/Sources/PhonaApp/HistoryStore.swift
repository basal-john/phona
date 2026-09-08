import Foundation
import PhonaCore
import SwiftUI

/// One flag the speaker raised, as written by the daemon's FLAG command.
///
/// `actual` is what they say they really said, and it is the only ground truth anywhere in
/// the record. The history file knows what was heard and what was delivered, never what was
/// meant, so this is the single most useful field in the whole store.
struct Correction: Sendable, Equatable {
    let flaggedAt: Date?
    let actual: String?
}

/// Everything the window reads off disk, gathered in one background pass.
///
/// One value rather than several published properties, because the panes cross-reference
/// each other. A half-applied load would show a row count from the new history against a
/// dictionary count from the old config, and a reader has no way to tell that happened.
struct HistorySnapshot: Sendable {
    var rows: [HistoryRow] = []
    var insights: Insights
    var corrections: [Date: Correction] = [:]
    var dictionary: [String] = []
    var replacements: [String: String] = [:]
    var typingWordsPerMinute: Double = HistoryStore.defaultTypingWordsPerMinute
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

    var rows: [HistoryRow] { snapshot.rows }
    var insights: Insights { snapshot.insights }

    /// Newest first, which is the order every list in the window shows.
    ///
    /// The parser hands rows back in file order, oldest first, and the archives are
    /// concatenated in that order too. Sorting by timestamp rather than reversing, because
    /// an archive rotation that lands mid-second can interleave two files.
    @Published private(set) var descending: [HistoryRow] = []

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        queue.async { [weak self] in
            let loaded = HistoryStore.read()
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.snapshot = loaded.snapshot
                self.descending = loaded.snapshot.rows.sorted { $0.ts > $1.ts }
                self.hasHistoryFile = loaded.hasHistoryFile
                self.isLoading = false
            }
        }
    }

    /// Persist a new typing speed and recompute, without re-reading a megabyte of history.
    ///
    /// The rate is only ever a divisor over rows already in hand, so a change to it is
    /// arithmetic rather than a load. Written with `Settings.set`, which rewrites one key and
    /// leaves the rest of config.json alone, because the daemon reads that same file.
    func setTypingWordsPerMinute(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        Settings.set(HistoryStore.typingSpeedKey, rate)
        var updated = snapshot
        updated.typingWordsPerMinute = rate
        updated.insights = Insights.compute(rows: updated.rows,
                                            typingWordsPerMinute: rate,
                                            calendar: .current,
                                            now: Date(),
                                            activityDays: HistoryStore.activityDays)
        snapshot = updated
    }

    /// The flag on a row, when the speaker raised one.
    func correction(for row: HistoryRow) -> Correction? {
        snapshot.corrections[row.ts]
    }

    func isFlagged(_ row: HistoryRow) -> Bool {
        snapshot.corrections[row.ts] != nil
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
        snapshot.dictionary = (config["dictionary"] as? [String]) ?? []
        snapshot.replacements = (config["replacements"] as? [String: String]) ?? [:]
        snapshot.sttModel = nonEmpty(config["stt_model"])
        snapshot.llmModel = nonEmpty(config["llm_model"])
        snapshot.cloudModel = nonEmpty(config["cloud_model"])
        return (snapshot, !paths.isEmpty)
    }

    /// `corrections.jsonl`, keyed by the timestamp of the history row each flag points at.
    ///
    /// The flag does not live on the history row. `Insights.flaggedCount` reads an optional
    /// `flagged` key that the engine never writes, so it is always zero, and the real record
    /// is this separate append-only file. Joining on `ts` is what makes the flagged filter
    /// and the detail pane's ground truth possible at all.
    ///
    /// A later flag on the same row wins, because a speaker who flags twice is correcting
    /// their own first attempt.
    private static func readCorrections(timeZone: TimeZone) -> [Date: Correction] {
        let url = Paths.base.appendingPathComponent("corrections.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let formatter = stampFormatter(timeZone)
        var flags: [Date: Correction] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stamp = object["ts"] as? String,
                  let ts = formatter.date(from: stamp) else { continue }
            let flaggedAt = (object["flagged_at"] as? String).flatMap(formatter.date(from:))
            flags[ts] = Correction(flaggedAt: flaggedAt, actual: nonEmpty(object["actual"]))
        }
        return flags
    }

    /// The same naive local wall clock the history parser reads, for the same reason: the
    /// engine writes `time.strftime("%Y-%m-%dT%H:%M:%S")` with no zone, so parsing it as UTC
    /// would shift every flag by the machine's offset and no flag would ever join a row.
    private static func stampFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
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
