import Foundation

/// Which key produced a dictation, and therefore whether its text left the machine.
public enum Route: String, Sendable {
    case local
    case cloud
}

/// One line of `history.jsonl`, already parsed and already sanitised.
///
/// The engine has written this file for every release so far, so the shape is a union of
/// several vintages rather than one schema. Older rows carry no `backend` and no model
/// identity, and rows from the FIX command carry `seconds: 0` because nobody spoke. Every
/// optional here is a field that is genuinely absent in the wild, not a convenience.
public struct HistoryRow: Sendable, Equatable {
    public let ts: Date
    public let source: String?
    public let mode: String?
    public let backend: String?
    public let sttModel: String?
    public let llmModel: String?
    public let cloudModel: String?
    public let style: String?
    public let raw: String
    public let text: String
    public let seconds: Double
    public let sttSecs: Double
    public let llmSecs: Double
    public let guarded: Bool
    public let guardReason: String?
    public let trimmed: Bool
    public let audio: String?
    public let flagged: Bool

    public init(ts: Date,
                source: String?,
                mode: String?,
                backend: String?,
                sttModel: String?,
                llmModel: String?,
                cloudModel: String?,
                style: String?,
                raw: String,
                text: String,
                seconds: Double,
                sttSecs: Double,
                llmSecs: Double,
                guarded: Bool,
                guardReason: String?,
                trimmed: Bool,
                audio: String?,
                flagged: Bool = false) {
        self.ts = ts
        self.source = source
        self.mode = mode
        self.backend = backend
        self.sttModel = sttModel
        self.llmModel = llmModel
        self.cloudModel = cloudModel
        self.style = style
        self.raw = raw
        self.text = text
        self.seconds = seconds
        self.sttSecs = sttSecs
        self.llmSecs = llmSecs
        self.guarded = guarded
        self.guardReason = guardReason
        self.trimmed = trimmed
        self.audio = audio
        self.flagged = flagged
    }

    /// `mode` says which key the speaker pressed, `backend` says whether the cloud actually
    /// answered. A cloud request that is refused or that fails falls back to the local model
    /// and records no backend, so only a backend proves the text left the machine. Showing
    /// the mode instead would claim a privacy boundary was crossed when it was not.
    public var route: Route {
        backend == nil ? .local : .cloud
    }

    /// Over `text`, what was delivered, never `raw`, what the transcriber heard. The
    /// correction stage adds and removes words, so counting `raw` measures the wrong thing.
    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// A FIX-command row was typed, not spoken, and carries `seconds: 0`. It is a real
    /// dictation for counting purposes and can never contribute speaking time or a
    /// speaking rate. Only an explicit `source` of voice earns that.
    public var isSpoken: Bool {
        source == "voice"
    }
}

/// Reads `history.jsonl` without ever letting one bad line cost a whole file.
public enum HistoryParser {

    private static let timestampFormat = "yyyy-MM-dd'T'HH:mm:ss"

    /// The engine writes `time.strftime("%Y-%m-%dT%H:%M:%S")`, a naive local wall clock with
    /// no zone and no offset. Parsing it as UTC shifts every row by the machine's offset,
    /// which is how a dictation lands on the wrong day, so the zone is always passed in.
    private static func makeFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = timestampFormat
        return formatter
    }

    public static func row(from line: String, timeZone: TimeZone) -> HistoryRow? {
        row(from: line, formatter: makeFormatter(timeZone))
    }

    public static func rows(from contents: String, timeZone: TimeZone) -> [HistoryRow] {
        let formatter = makeFormatter(timeZone)
        var parsed: [HistoryRow] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            if let row = row(from: String(line), formatter: formatter) {
                parsed.append(row)
            }
        }
        return parsed
    }

    /// The readable history files oldest-first, so a caller can concatenate them in order.
    ///
    /// The engine keeps every archive as `history.jsonl.<n>` with `.1` the oldest and a
    /// higher number meaning newer, then the live `history.jsonl` last. The suffixes sort
    /// numerically, because as strings `.10` would land between `.1` and `.2`. A missing
    /// file or a directory that cannot be listed yields whatever does exist.
    public static func archivePaths(base: URL) -> [URL] {
        let manager = FileManager.default
        let prefix = "history.jsonl."
        let names = (try? manager.contentsOfDirectory(atPath: base.path)) ?? []
        var numbered: [(Int, URL)] = []
        for name in names {
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            guard !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let index = Int(suffix) else { continue }
            let url = base.appendingPathComponent(name)
            guard manager.isReadableFile(atPath: url.path) else { continue }
            numbered.append((index, url))
        }
        numbered.sort { $0.0 < $1.0 }
        var paths = numbered.map { $0.1 }
        let live = base.appendingPathComponent("history.jsonl")
        if manager.isReadableFile(atPath: live.path) {
            paths.append(live)
        }
        return paths
    }

    private static func row(from line: String, formatter: DateFormatter) -> HistoryRow? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any] else { return nil }
        guard let stamp = string(object["ts"]), let ts = formatter.date(from: stamp) else { return nil }
        guard let text = object["text"] as? String else { return nil }
        return HistoryRow(ts: ts,
                          source: string(object["source"]),
                          mode: string(object["mode"]),
                          backend: string(object["backend"]),
                          sttModel: string(object["stt_model"]),
                          llmModel: string(object["llm_model"]),
                          cloudModel: string(object["cloud_model"]),
                          style: string(object["style"]),
                          raw: object["raw"] as? String ?? "",
                          text: text,
                          seconds: number(object["seconds"]),
                          sttSecs: number(object["stt_secs"]),
                          llmSecs: number(object["llm_secs"]),
                          guarded: boolean(object["guarded"]),
                          guardReason: string(object["guard_reason"]),
                          trimmed: boolean(object["trimmed"]),
                          audio: string(object["audio"]),
                          flagged: boolean(object["flagged"]))
    }

    /// An absent key, a JSON null and an empty string all mean the same thing to every
    /// caller here, and the engine writes all three for the same field across vintages.
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A rate computed from a NaN or an infinity poisons every total it touches, so a
    /// number that is not finite is treated as absent.
    private static func number(_ value: Any?) -> Double {
        guard let raw = value as? NSNumber else { return 0 }
        let double = raw.doubleValue
        return double.isFinite ? double : 0
    }

    private static func boolean(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }
}
