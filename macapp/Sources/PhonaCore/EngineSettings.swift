import Foundation

/// The settings the daemon reads only once, at startup.
///
/// `load_config()` runs a single time in the daemon's `main` and is stored on the engine,
/// with no reload path and no file watcher, so changing any of these takes effect only after
/// a restart. That is what separates them from the app-side settings, which apply the moment
/// they are toggled. Holding them in one comparable value is what lets the Settings window
/// offer a restart only when one is genuinely needed.
public struct EngineSettings: Equatable {
    public var dictionary: [String]
    public var biasVocabulary: Bool
    public var replacements: [String: String]
    public var spokenLayout: Bool

    public init(dictionary: [String],
                biasVocabulary: Bool,
                replacements: [String: String],
                spokenLayout: Bool) {
        self.dictionary = dictionary
        self.biasVocabulary = biasVocabulary
        self.replacements = replacements
        self.spokenLayout = spokenLayout
    }

    /// One word per line, trimmed, with blank lines dropped.
    public static func words(fromText text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func text(fromWords words: [String]) -> String {
        words.joined(separator: "\n")
    }

    /// One `wrong = right` pair per line. A line with no separator is skipped rather than
    /// stored, because it is what a half-typed line looks like. Only the first separator
    /// splits, so an equals sign inside the replacement value survives.
    public static func replacements(fromText text: String) -> [String: String] {
        var pairs: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { pairs[key] = value }
        }
        return pairs
    }

    /// Sorted, so reopening the window does not reorder the user's own list under them.
    public static func text(fromReplacements pairs: [String: String]) -> String {
        pairs.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: "\n")
    }
}
