import Foundation

/// How many frames to ask for in one microphone tap buffer.
///
/// `-[AVAudioNode installTapOnBus:bufferSize:format:block:]` documents its buffer size as
/// "Supported range is [100, 400] ms", and the size is in frames, so the legal frame count
/// depends entirely on the rate the device is running at. A fixed frame count cannot satisfy
/// that on a machine whose inputs run at 16, 24, 44.1 and 48 kHz, which is what a Bluetooth
/// headset, a webcam, a built-in microphone and a USB microphone come to.
///
/// The old code passed a fixed 1024 frames, which is 21 ms at 48 kHz and 43 ms at 24 kHz.
/// Both are below the documented floor, on the one call in the app that aborts the process
/// when it is unhappy. Asking inside the documented window costs roughly 80 ms before the
/// first buffer reaches the waveform and loses no audio, because the engine keeps capturing
/// whether or not the tap has been handed a buffer yet.
public enum CaptureBuffer {
    /// The documented floor, and what this asks for, because the first buffer is what the
    /// speaker is waiting to see the waveform move on.
    public static let minimumSeconds: Double = 0.1

    /// The documented ceiling. Nothing here asks for it. It is the bound the result is
    /// checked against.
    public static let maximumSeconds: Double = 0.4

    /// Frames to request for a device running at `sampleRate`.
    ///
    /// Returns a count inside the documented window for any rate a real device reports.
    /// `sampleRate` is whatever `outputFormat(forBus:)` said, so it is guarded rather than
    /// trusted: a device mid-disconnect can report zero, and a frame count of zero would be
    /// a second contract violation on top of the one being fixed.
    public static func frames(forSampleRate sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return UInt32(48_000 * minimumSeconds)
        }
        let wanted = sampleRate * minimumSeconds
        let ceiling = sampleRate * maximumSeconds
        return UInt32(min(max(wanted, 1), ceiling).rounded())
    }

    /// Whether a frame count lands inside the documented window at a given rate.
    ///
    /// Exists so the rule is stated once and the tests check the same thing the caller does,
    /// rather than restating the arithmetic and agreeing with themselves.
    public static func isSupported(frames: UInt32, atSampleRate sampleRate: Double) -> Bool {
        guard sampleRate.isFinite, sampleRate > 0 else { return false }
        let seconds = Double(frames) / sampleRate
        return seconds >= minimumSeconds && seconds <= maximumSeconds
    }
}
