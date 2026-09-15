import XCTest
@testable import PhonaCore

/// The rates the four inputs on the machine that crashed actually run at, so the cases are
/// devices rather than round numbers: AirPods at 24 kHz, a webcam at 16 kHz, the built-in
/// microphone at 44.1 kHz and a USB microphone at 48 kHz.
final class CaptureBufferTests: XCTestCase {
    private let deviceRates: [Double] = [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 96_000, 192_000]

    func testEveryDeviceRateLandsInsideTheDocumentedWindow() {
        for rate in deviceRates {
            let frames = CaptureBuffer.frames(forSampleRate: rate)
            XCTAssertTrue(
                CaptureBuffer.isSupported(frames: frames, atSampleRate: rate),
                "\(frames) frames is \(Double(frames) / rate * 1000) ms at \(rate) Hz, outside [100, 400] ms")
        }
    }

    /// The fixed count the old code passed. Kept as a test so the regression is named rather
    /// than remembered.
    func testTheOldFixedFrameCountWasOutOfRangeAtEveryDeviceRate() {
        for rate in deviceRates where rate >= 16_000 {
            XCTAssertFalse(
                CaptureBuffer.isSupported(frames: 1024, atSampleRate: rate),
                "1024 frames should be below the floor at \(rate) Hz")
        }
    }

    func testItAsksForTheFloorRatherThanTheCeiling() {
        XCTAssertEqual(CaptureBuffer.frames(forSampleRate: 48_000), 4_800)
        XCTAssertEqual(CaptureBuffer.frames(forSampleRate: 24_000), 2_400)
        XCTAssertEqual(CaptureBuffer.frames(forSampleRate: 16_000), 1_600)
        XCTAssertEqual(CaptureBuffer.frames(forSampleRate: 44_100), 4_410)
    }

    /// A device mid-disconnect reports zero, and a zero frame count would be a second contract
    /// violation on the call the whole change exists to keep legal.
    /// The first version rounded to nearest, which is under the floor for any rate that is
    /// not a multiple of ten. The device list in the other tests is all round numbers, so it
    /// passed. This sweeps instead of sampling.
    func testEveryIntegerRateFromEightToNinetySixKilohertzIsInsideTheWindow() {
        var offenders: [Double] = []
        for rate in stride(from: 8_000.0, through: 96_000.0, by: 1.0) {
            if !CaptureBuffer.isSupported(frames: CaptureBuffer.frames(forSampleRate: rate),
                                          atSampleRate: rate) {
                offenders.append(rate)
            }
        }
        XCTAssertEqual(offenders.count, 0,
                       "rates outside the window, first few: \(offenders.prefix(5))")
    }

    func testANonMultipleOfTenRateRoundsUpRatherThanUnderTheFloor() {
        XCTAssertEqual(CaptureBuffer.frames(forSampleRate: 44_101), 4_411,
                       "4410 frames at 44101 Hz is 99.998 ms, under the 100 ms floor")
        XCTAssertEqual(CaptureBuffer.frames(forSampleRate: 8_001), 801)
    }

    func testAnUnusableRateStillProducesALegalFrameCount() {
        for bad in [0, -1, Double.nan, Double.infinity] {
            let frames = CaptureBuffer.frames(forSampleRate: bad)
            XCTAssertGreaterThan(frames, 0, "a frame count of 0 is never legal")
            XCTAssertTrue(CaptureBuffer.isSupported(frames: frames, atSampleRate: 48_000))
        }
    }

    func testTheWindowBoundsAreInclusive() {
        XCTAssertTrue(CaptureBuffer.isSupported(frames: 4_800, atSampleRate: 48_000), "exactly 100 ms")
        XCTAssertTrue(CaptureBuffer.isSupported(frames: 19_200, atSampleRate: 48_000), "exactly 400 ms")
        XCTAssertFalse(CaptureBuffer.isSupported(frames: 4_799, atSampleRate: 48_000))
        XCTAssertFalse(CaptureBuffer.isSupported(frames: 19_201, atSampleRate: 48_000))
    }

    func testSupportIsFalseForARateThatMakesNoSense() {
        XCTAssertFalse(CaptureBuffer.isSupported(frames: 4_800, atSampleRate: 0))
        XCTAssertFalse(CaptureBuffer.isSupported(frames: 4_800, atSampleRate: .nan))
    }
}
