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
        XCTAssertEqual(DictionaryReach.resolve(sttModel: parakeet, useInitialPrompt: false),
                       .modelTakesNoHint)
        XCTAssertEqual(DictionaryReach.resolve(sttModel: parakeet, useInitialPrompt: true),
                       .modelTakesNoHint)
    }

    /// `use_initial_prompt` defaults to false, so switching to Whisper on its own changes
    /// nothing. That was the remedy the Dictionary pane used to offer.
    func testWhisperWithTheFlagOffStillReachesNothing() {
        XCTAssertEqual(DictionaryReach.resolve(sttModel: whisper, useInitialPrompt: false),
                       .hintAvailableButOff)
    }

    func testWhisperWithTheFlagOnFeedsTheTranscriber() {
        XCTAssertEqual(DictionaryReach.resolve(sttModel: whisper, useInitialPrompt: true),
                       .hintInUse)
    }
}
