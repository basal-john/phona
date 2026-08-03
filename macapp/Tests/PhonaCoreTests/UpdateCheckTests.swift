import XCTest
@testable import PhonaCore

/// Regression: the app reported 1.0.0 while the release tag said v1.1.0, so a naive
/// comparison would either miss updates or offer one that already exists.
final class UpdateCheckTests: XCTestCase {

    func testNewerVersionsAreDetected() {
        XCTAssertTrue(UpdateCheck.isNewer("1.2.0", than: "1.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.2.1", than: "1.2.0"))
    }

    /// A string compare would say 1.10.0 is older than 1.9.0, because "1" sorts before "9".
    func testDoubleDigitComponentsCompareNumerically() {
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.9.0", than: "1.10.0"))
    }

    func testSameVersionIsNotAnUpdate() {
        XCTAssertFalse(UpdateCheck.isNewer("1.2.0", than: "1.2.0"))
    }

    func testOlderVersionIsNotAnUpdate() {
        XCTAssertFalse(UpdateCheck.isNewer("1.1.0", than: "1.2.0"))
    }

    /// Release tags carry a leading v, bundle versions do not.
    func testLeadingLetterIsIgnored() {
        XCTAssertTrue(UpdateCheck.isNewer("v1.3.0", than: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.2.0", than: "1.2.0"))
    }

    func testMissingComponentsAreTreatedAsZero() {
        XCTAssertTrue(UpdateCheck.isNewer("1.3", than: "1.2.9"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2", than: "1.2.0"))
    }

    func testReleaseEndpointsPointAtThisProject() {
        XCTAssertTrue(UpdateCheck.releasesAPI.absoluteString.contains("basal-john/phona"))
        XCTAssertTrue(UpdateCheck.releasesPage.absoluteString.contains("basal-john/phona"))
    }
}
