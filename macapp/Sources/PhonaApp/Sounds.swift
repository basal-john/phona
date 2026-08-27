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
///   stop     D5          the note start landed on, held alone and briefly
///   done     D5 -> A5    the same interval an octave up, resolved
///   nothing  D5 -> A4    the mirror of start, falling, nothing landed
///
/// So a completed dictation is heard as a phrase that opens and closes, and a cancelled
/// one as the same phrase turned back on itself. The stop is the pause in the middle of
/// that phrase, which is why it is one note rather than two and 120 ms rather than 215.
enum Cue: String {
    case start = "start"
    /// The key was heard. Silent for a while, on the reasoning that start, stop and done
    /// inside about a second was more noise than information and that the done cue follows
    /// almost immediately. It does not: transcription and the correction pass run 1.7 to 7
    /// seconds on the measured log, and through all of it the only confirmation that the
    /// tap registered was the HUD, which is on screen and therefore not where the speaker
    /// is looking. So it is back, kept short and single-noted so the three cues still read
    /// as one phrase.
    case stop = "stop"
    case done = "done"
    /// Nothing usable was captured. Not a failure, so it must not sound like one.
    case nothing = "nothing"

    private static var cache: [String: NSSound] = [:]

    /// Every cue is played on this queue and nowhere else, which both keeps the cache
    /// accesses serialised and keeps the blocking off the main thread.
    private static let queue = DispatchQueue(label: "com.basalona.phona.cues")

    /// Play the cue, off the main thread.
    ///
    /// `NSSound.play()` blocks while the default output device powers back up, and macOS
    /// powers it down after a few seconds of silence. Measured on the bundled file: 16 ms
    /// when the device is already awake, 144 ms after 5 s idle, 534 ms after 15 s, and 796 ms
    /// on the first call in a fresh process.
    ///
    /// That is why this must not run on the main thread. Nothing is drawn until the main
    /// thread returns to its run loop, so a cue played there held the HUD off screen for as
    /// long as it blocked, and the HUD is the thing the speaker is waiting for. A cue that
    /// arrives a few milliseconds late is not noticeable. A cue that gates every pixel is.
    func play() {
        Self.queue.async { self.playNow() }
    }

    /// Prefers the bundled file, falling back to the system set so the app still makes sense
    /// if a resource is missing from the bundle.
    ///
    /// A cue is inaudible on an idle Bluetooth speaker, and that is not a bug here. The
    /// cues run 120 to 260 ms, while an output device that has gone quiet takes 474 to 534 ms
    /// to come back, so the sound finishes before the link is carrying audio. `play()` still
    /// returns true, because queuing it succeeded. Chased once already: the file, the bundle
    /// lookup and the thread were all verified fine before the output device was checked.
    /// Wired and built-in output are unaffected, and the accepted answer is to live with it
    /// rather than pad every cue with silence or hold an audio stream open.
    private func playNow() {
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
