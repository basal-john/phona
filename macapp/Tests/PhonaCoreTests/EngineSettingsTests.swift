import XCTest
@testable import PhonaCore

final class EngineSettingsTests: XCTestCase {

    /// The Save button is driven by comparing the form against what was loaded, so a
    /// trailing newline or a stray space in the vocabulary box must not read as a change.
    /// Otherwise Save offers an engine restart for an edit the user did not make.
    func testBlankLinesAndPaddingAreNotAChange() {
        let clean = EngineSettings.words(fromText: "Phona\nJira")
        let messy = EngineSettings.words(fromText: "  Phona  \n\n Jira \n")
        XCTAssertEqual(clean, messy)
        XCTAssertEqual(clean, ["Phona", "Jira"])
    }

    func testWordOrderIsPreserved() {
        XCTAssertEqual(EngineSettings.words(fromText: "beta\nalpha"), ["beta", "alpha"])
    }

    func testWordsRoundTripThroughText() {
        let words = ["Phona", "Jira", "Whisper"]
        XCTAssertEqual(EngineSettings.words(fromText: EngineSettings.text(fromWords: words)), words)
    }

    func testReplacementsParseOnPaddedPairs() {
        let pairs = EngineSettings.replacements(fromText: "con job = cron job\n free tire = free tier ")
        XCTAssertEqual(pairs, ["con job": "cron job", "free tire": "free tier"])
    }

    /// A line the user is halfway through typing has no separator yet, and must be skipped
    /// rather than stored under an empty key.
    func testLineWithoutASeparatorIsIgnored() {
        XCTAssertEqual(EngineSettings.replacements(fromText: "con job"), [:])
    }

    func testEmptyKeyIsDropped() {
        XCTAssertEqual(EngineSettings.replacements(fromText: " = cron job"), [:])
    }

    /// Only the first separator splits, so a replacement whose value contains an equals
    /// sign survives intact.
    func testOnlyTheFirstSeparatorSplits() {
        XCTAssertEqual(EngineSettings.replacements(fromText: "arrow = a = b"), ["arrow": "a = b"])
    }

    func testReplacementsRoundTripThroughText() {
        let pairs = ["con job": "cron job", "free tire": "free tier"]
        let text = EngineSettings.text(fromReplacements: pairs)
        XCTAssertEqual(EngineSettings.replacements(fromText: text), pairs)
    }

    func testReplacementTextIsSortedSoTheBoxDoesNotReorderItself() {
        let text = EngineSettings.text(fromReplacements: ["zulu": "z", "alpha": "a"])
        XCTAssertEqual(text, "alpha = a\nzulu = z")
    }

    func testIdenticalSettingsAreEqual() {
        XCTAssertEqual(Self.sample(), Self.sample())
    }

    func testEachFieldBreaksEquality() {
        var mode = Self.sample()
        mode.mode = "polish"
        XCTAssertNotEqual(Self.sample(), mode)

        var dictionary = Self.sample()
        dictionary.dictionary = ["Phona", "Extra"]
        XCTAssertNotEqual(Self.sample(), dictionary)

        var bias = Self.sample()
        bias.biasVocabulary = true
        XCTAssertNotEqual(Self.sample(), bias)

        var replacements = Self.sample()
        replacements.replacements = ["a": "b"]
        XCTAssertNotEqual(Self.sample(), replacements)

        var layout = Self.sample()
        layout.spokenLayout = false
        XCTAssertNotEqual(Self.sample(), layout)
    }

    private static func sample() -> EngineSettings {
        EngineSettings(mode: "grammar",
                       dictionary: ["Phona"],
                       biasVocabulary: false,
                       replacements: ["con job": "cron job"],
                       spokenLayout: true)
    }
}
