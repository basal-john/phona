import Foundation

/// One flag the speaker raised, as written by the daemon's FLAG command.
///
/// `actual` is what they say they really said, and it is the only ground truth anywhere in
/// the record. The history file knows what was heard and what was delivered, never what was
/// meant, so this is the single most useful field in the whole store.
public struct Correction: Sendable, Equatable {
    public let flaggedAt: Date?
    public let actual: String?

    public init(flaggedAt: Date?, actual: String?) {
        self.flaggedAt = flaggedAt
        self.actual = actual
    }
}

/// Which dictation a flag points at.
///
/// The stamp alone is not it. The engine writes a whole second, so two dictations a fraction
/// apart share one, and keying on that made every row in a busy second read as flagged and
/// print another dictation's ground truth. `flag_last` writes `heard` and `returned` from the
/// flagged row's own `raw` and `text`, so those two carry the rest of the identity.
///
/// Two rows in one second whose transcripts and deliveries are both identical stay
/// indistinguishable, and there is nothing in either file that would separate them.
public struct CorrectionKey: Hashable, Sendable {
    public let ts: Date
    public let heard: String
    public let returned: String

    public init(ts: Date, heard: String, returned: String) {
        self.ts = ts
        self.heard = heard
        self.returned = returned
    }
}

/// Reads `corrections.jsonl` and joins it to the history rows it points at.
public enum CorrectionLog {

    /// The key a history row would be flagged under, from the same two fields the daemon
    /// copies into the flag record.
    public static func key(for row: HistoryRow) -> CorrectionKey {
        CorrectionKey(ts: row.ts, heard: row.raw, returned: row.text)
    }

    /// Every flag on disk, indexed by the row it identifies.
    ///
    /// A later flag on the same row wins, because a speaker who flags twice is correcting
    /// their own first attempt. A line that carries no stamp, or one this formatter cannot
    /// read, is skipped rather than allowed to cost the rest of the file.
    ///
    /// The stamp format is `HistoryParser`'s own, shared rather than repeated: the engine
    /// writes both files with `time.strftime("%Y-%m-%dT%H:%M:%S")`, a naive local wall clock,
    /// and reading one of them as UTC would mean no flag ever joins a row.
    public static func flags(from contents: String,
                             timeZone: TimeZone) -> [CorrectionKey: Correction] {
        let formatter = HistoryParser.makeFormatter(timeZone)
        var flags: [CorrectionKey: Correction] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: data),
                  let object = any as? [String: Any],
                  let stamp = object["ts"] as? String,
                  let ts = formatter.date(from: stamp) else { continue }
            let key = CorrectionKey(ts: ts,
                                    heard: object["heard"] as? String ?? "",
                                    returned: object["returned"] as? String ?? "")
            let flaggedAt = (object["flagged_at"] as? String).flatMap(formatter.date(from:))
            flags[key] = Correction(flaggedAt: flaggedAt, actual: nonEmpty(object["actual"]))
        }
        return flags
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
