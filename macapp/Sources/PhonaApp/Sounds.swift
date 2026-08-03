import AppKit
import Foundation

/// Audio cues.
///
/// The cues are bundled rather than taken from the system set, because the system set has
/// nothing suitable for "heard nothing". `Basso` is the macOS error alert, and using it
/// when a dictation simply had no speech in it scolds the user for a non-event. These are
/// quiet, short, and deliberately unalarming.
enum Cue: String {
    case start = "start"
    /// Deliberately silent. Start, stop and done fired three cues inside about a second,
    /// which is more noise than information. The stop is the least useful of the three,
    /// because releasing the key is something you just did and the done cue follows it
    /// almost immediately.
    case stop = "stop"
    case done = "done"
    /// Nothing usable was captured. Not a failure, so it must not sound like one.
    case nothing = "nothing"

    private static var cache: [String: NSSound] = [:]

    func play() {
        if self == .stop { return }
        if let cached = Self.cache[rawValue] {
            cached.stop()
            cached.play()
            return
        }
        // Bundled first, then the system fallback, so the app still makes sense if a
        // resource is missing from the bundle.
        if let url = Bundle.main.url(forResource: rawValue, withExtension: "aiff",
                                    subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: false) {
            Self.cache[rawValue] = sound
            sound.play()
            return
        }
        if let fallback = NSSound(named: systemFallback) {
            Self.cache[rawValue] = fallback
            fallback.play()
        }
    }

    private var systemFallback: NSSound.Name {
        switch self {
        case .start: return "Tink"
        case .stop: return "Pop"
        case .done: return "Glass"
        case .nothing: return "Morse"
        }
    }
}
