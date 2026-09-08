import Foundation

/// Whether the words in the dictionary reach the transcriber, which is the one claim the
/// Dictionary pane leads with and the one it used to get wrong.
///
/// Three settings decide it together, so none of them alone can be stated as an answer. The
/// speech model decides whether the loader can take a vocabulary hint at all,
/// `use_initial_prompt` decides whether the daemon hands it one when it can, and the
/// dictionary decides whether there is anything to hand over.
public enum DictionaryReach: Sendable, Equatable {
    /// The speech model is not a Whisper repo, so no hint reaches it and no setting changes
    /// that.
    case modelTakesNoHint

    /// A Whisper repo, but the joined dictionary is empty, so the daemon passes no
    /// `initial_prompt` whatever the flag says. Turning the flag on changes nothing here.
    case nothingToSend

    /// A Whisper repo with words to send and `use_initial_prompt` off, which is the default.
    /// Nothing reaches the transcriber, and turning that one flag on is what would change it.
    case hintAvailableButOff

    /// A Whisper repo with words to send and `use_initial_prompt` on. The dictionary is
    /// handed to the transcriber as its initial prompt, so it does bias what is heard.
    case hintInUse

    /// Emptiness is checked before the flag, so the answer never offers a remedy that would
    /// not work on its own. A pane that told somebody to turn the flag on while their
    /// dictionary was empty would have them change a setting and see nothing happen.
    public static func resolve(sttModel: String?,
                               useInitialPrompt: Bool,
                               dictionary: [String]) -> DictionaryReach {
        guard isWhisper(sttModel) else { return .modelTakesNoHint }
        guard !hint(from: dictionary).isEmpty else { return .nothingToSend }
        return useInitialPrompt ? .hintInUse : .hintAvailableButOff
    }

    /// Exactly what the daemon builds. `transcribe` joins the configured list with ", " and
    /// passes an `initial_prompt` only when that join is non-empty, so this mirrors the
    /// separator rather than counting entries: a list of one empty string sends nothing and
    /// a list of two sends the separator between them.
    public static func hint(from dictionary: [String]) -> String {
        dictionary.joined(separator: ", ")
    }

    /// Mirrors `stt_backend_for` in the daemon, which picks the loader from the repo id and
    /// from nothing else: a repo id containing "parakeet" is Parakeet and everything else,
    /// including an absent one, is Whisper.
    public static func isWhisper(_ sttModel: String?) -> Bool {
        !(sttModel ?? "").lowercased().contains("parakeet")
    }
}
