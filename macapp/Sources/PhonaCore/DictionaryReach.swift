import Foundation

/// Whether the words in the dictionary reach the transcriber, which is the one claim the
/// Dictionary pane leads with and the one it used to get wrong.
///
/// Two settings decide it together, so neither alone can be stated as an answer. The speech
/// model decides whether the loader can take a vocabulary hint at all, and
/// `use_initial_prompt` decides whether the daemon hands it one when it can.
public enum DictionaryReach: Sendable, Equatable {
    /// The speech model is not a Whisper repo, so no hint reaches it and no setting changes
    /// that.
    case modelTakesNoHint

    /// A Whisper repo with `use_initial_prompt` off, which is the default. Nothing reaches
    /// the transcriber, and turning that one flag on is what would change it.
    case hintAvailableButOff

    /// A Whisper repo with `use_initial_prompt` on. The dictionary is handed to the
    /// transcriber as its initial prompt, so it does bias what is heard.
    case hintInUse

    public static func resolve(sttModel: String?, useInitialPrompt: Bool) -> DictionaryReach {
        guard isWhisper(sttModel) else { return .modelTakesNoHint }
        return useInitialPrompt ? .hintInUse : .hintAvailableButOff
    }

    /// Mirrors `stt_backend_for` in the daemon, which picks the loader from the repo id and
    /// from nothing else: a repo id containing "parakeet" is Parakeet and everything else,
    /// including an absent one, is Whisper.
    public static func isWhisper(_ sttModel: String?) -> Bool {
        !(sttModel ?? "").lowercased().contains("parakeet")
    }
}
