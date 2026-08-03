import AppKit
import Foundation

/// Audio cues.
///
/// Bundled rather than taken from the system set. Partly because the system set has
/// nothing suitable for "heard nothing" (`Basso` is the error alert, and using it when a
/// dictation simply had no speech in it scolds the user for a non-event), and partly so
/// the three cues can be one family instead of three unrelated noises.
///
/// They share two pitches, A and D, and let direction and register carry the meaning:
///
///   start    A4 -> D5    rising, opening
///   done     D5 -> A5    the same interval an octave up, resolved
///   nothing  D5 -> A4    the mirror of start, falling, nothing landed
///
/// So a completed dictation is heard as a phrase that opens and closes, and a cancelled
/// one as the same phrase turned back on itself.
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

    /// Play the cue, preferring the bundled file and falling back to the system set so the
    /// app still makes sense if a resource is missing from the bundle.
    func play() {
        if self == .stop { return }
        if let cached = Self.cache[rawValue] {
            cached.stop()
            cached.play()
            return
        }
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
