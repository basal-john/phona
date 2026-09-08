import XCTest
@testable import PhonaCore

final class DictionaryReachTests: XCTestCase {

    private let parakeet = "mlx-community/parakeet-tdt-0.6b-v3"
    private let whisper = "mlx-community/whisper-large-v3-turbo"

    /// `stt_backend_for` in the daemon reads the repo id and nothing else: "parakeet" in the
    /// id means Parakeet, and everything else, an absent id included, means Whisper.
    func testWhisperIsEverythingThatIsNotAParakeetRepo() {
        XCTAssertFalse(DictionaryReach.isWhisper(parakeet))
        XCTAssertFalse(DictionaryReach.isWhisper("MLX-Community/Parakeet-TDT"))
        XCTAssertTrue(DictionaryReach.isWhisper(whisper))
        XCTAssertTrue(DictionaryReach.isWhisper("some/other-model"))
        XCTAssertTrue(DictionaryReach.isWhisper(nil))
        XCTAssertTrue(DictionaryReach.isWhisper(""))
    }

    /// Parakeet takes no initial prompt at all, so the flag cannot change the answer.
    func testParakeetTakesNoHintWhateverTheFlagSays() {
        XCTAssertEqual(reach(parakeet, flag: false), .modelTakesNoHint)
        XCTAssertEqual(reach(parakeet, flag: true), .modelTakesNoHint)
    }

    /// `use_initial_prompt` defaults to false, so switching to Whisper on its own changes
    /// nothing. That was the remedy the Dictionary pane used to offer.
    func testWhisperWithTheFlagOffStillReachesNothing() {
        XCTAssertEqual(reach(whisper, flag: false), .hintAvailableButOff)
    }

    func testWhisperWithTheFlagOnFeedsTheTranscriber() {
        XCTAssertEqual(reach(whisper, flag: true), .hintInUse)
    }

    /// The daemon builds `", ".join(dictionary)` and only passes an `initial_prompt` when
    /// that is not empty, so the flag being on is not enough to claim words are reaching the
    /// transcriber. The pane used to claim it with an empty list.
    func testAnEmptyDictionaryReachesNothingEvenWithTheFlagOn() {
        XCTAssertEqual(reach(whisper, flag: true, words: []), .nothingToSend)
        XCTAssertEqual(reach(whisper, flag: false, words: []), .nothingToSend)
        XCTAssertEqual(reach(whisper, flag: true, words: [""]), .nothingToSend)
    }

    /// The mirror is of the join, not of the entry count. Two empty entries join to the
    /// separator between them, which the daemon does pass.
    func testTheHintIsWhatTheDaemonWouldJoin() {
        XCTAssertEqual(DictionaryReach.hint(from: []), "")
        XCTAssertEqual(DictionaryReach.hint(from: [""]), "")
        XCTAssertEqual(DictionaryReach.hint(from: ["", ""]), ", ")
        XCTAssertEqual(DictionaryReach.hint(from: ["Phona", "Jira"]), "Phona, Jira")
        XCTAssertEqual(reach(whisper, flag: true, words: ["", ""]), .hintInUse)
    }

    /// A model that takes no hint is the answer before emptiness, because no dictionary
    /// would change it.
    func testParakeetWithAnEmptyDictionaryStillNamesTheModel() {
        XCTAssertEqual(reach(parakeet, flag: true, words: []), .modelTakesNoHint)
    }

    private func reach(_ model: String,
                       flag: Bool,
                       words: [String] = ["Phona"]) -> DictionaryReach {
        DictionaryReach.resolve(sttModel: model, useInitialPrompt: flag, dictionary: words)
    }
}
