import Foundation

/// What the hotkey should do about one Option event.
public enum TapAction: Equatable {
    case none
    case start
    case stop
    case abort
}

/// Decides when a tap of Option starts or stops a dictation.
///
/// Pulled out of `HotkeyMonitor` because the monitor needs a live event tap and a real
/// keyboard, so its behaviour cannot otherwise be tested. This holds the whole decision and
/// the monitor only feeds it events.
///
/// A tap is Option pressed and released on its own. Nothing happens on the press, because a
/// press is also how every Option shortcut begins and the shortcut has to stay a shortcut.
/// The decision waits for the release, by which time any other key has already arrived and
/// set `dirty`.
///
/// Holding does nothing. `tapMaxDuration` is what separates a tap from a rest on the key, so
/// leaning on Option cannot open a recording that then runs to the five minute cap. The
/// ceiling is generous, because a tap that does not register is a worse failure than a rest
/// that does nothing: the first loses a sentence the speaker already said.
///
/// Stopping is deliberately easier than starting. Once a dictation is running, any Option
/// release ends it regardless of how long the key was down. Failing to stop leaves the
/// microphone open and the speaker unaware, which is the worse direction to be wrong in.
///
/// A shortcut during a dictation is ignored rather than treated as an abort. Option and Tab
/// mid-sentence is someone changing window while they talk, not someone cancelling.
public struct TapToggle {
    /// The longest an Option press can last and still count as a tap.
    public var tapMaxDuration: TimeInterval

    private var recording = false
    private var downSince: Date?
    private var dirty = false

    public init(tapMaxDuration: TimeInterval = 0.5) {
        self.tapMaxDuration = tapMaxDuration
    }

    public var isRecording: Bool { recording }

    /// Option alone went down.
    public mutating func optionDown(at now: Date) -> TapAction {
        downSince = now
        dirty = false
        return .none
    }

    /// Option went up, or stopped being the only modifier held.
    public mutating func optionUp(at now: Date) -> TapAction {
        let since = downSince
        downSince = nil
        let wasDirty = dirty
        dirty = false

        if recording {
            recording = false
            return .stop
        }
        guard !wasDirty, let since, now.timeIntervalSince(since) <= tapMaxDuration else {
            return .none
        }
        recording = true
        return .start
    }

    /// Another key arrived while Option was down, so this is a shortcut.
    public mutating func otherKeyPressed() -> TapAction {
        dirty = true
        return .none
    }

    /// Escape throws the recording away rather than transcribing it.
    public mutating func escapePressed() -> TapAction {
        guard recording else { return .none }
        recording = false
        downSince = nil
        dirty = false
        return .abort
    }

    /// The event tap was disabled and anything in flight is no longer trustworthy.
    ///
    /// Returns `.abort` when a dictation was running, because the release that would have
    /// ended it may already have been missed.
    public mutating func reset() -> TapAction {
        let wasRecording = recording
        recording = false
        downSince = nil
        dirty = false
        return wasRecording ? .abort : .none
    }
}
