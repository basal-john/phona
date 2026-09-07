import Foundation

/// Where text would land right now.
///
/// Lives here rather than on `FocusProbe` so the decisions below can be tested without an
/// Accessibility grant, a focused window, or a real pasteboard. `FocusProbe.Target` is an
/// alias for this type, so the probe keeps its own name for it at every call site.
public enum PasteTarget: Equatable {
    /// An editable element is focused. Pasting will land, and the clipboard can safely be put
    /// back afterwards.
    case editable
    /// Something is focused but it does not take text, or nothing is focused at all.
    case notEditable
    /// Accessibility could not tell us. Common in apps that expose little of their hierarchy,
    /// so this must not be treated as a failure.
    case unknown
}

/// What a paste is going to do, decided before anything touches the pasteboard.
///
/// Every one of these three answers used to be an expression inline in `Paster.paste`, mixed
/// in with `NSPasteboard`, a `CGEvent` and a dispatch delay, which is why none of them had a
/// test. They are the part that can be wrong without crashing: restoring the clipboard over a
/// dictation that never landed is how a dictation used to disappear twice over.
public struct PastePlan: Equatable {
    /// Whether to copy the current clipboard before replacing it.
    ///
    /// Only when it is going to be put back. Reading every representation of every item is not
    /// free: an item waiting on Universal Clipboard sends the read looking for another device,
    /// and an image is megabytes.
    public let takesSnapshot: Bool

    /// Whether to post Cmd+V.
    ///
    /// A confirmed non-target gets no keystroke at all, because in Finder Cmd+V means paste a
    /// file, which would either do nothing or do something unwanted. An unknown target does
    /// get one, since treating uncertainty as failure would refuse to type into every Electron
    /// app that exposes little of its hierarchy.
    public let sendsKeystroke: Bool

    /// Whether to put the previous clipboard back after the keystroke.
    ///
    /// Never when the caller asked to keep the dictation on the clipboard, and never when
    /// Accessibility could not confirm the paste had somewhere to go. The dictation staying on
    /// the clipboard is recoverable with one Cmd+V. A restore over a keystroke that went
    /// nowhere is not recoverable at all.
    public let restoresClipboard: Bool

    public init(restoreRequested: Bool, target: PasteTarget) {
        restoresClipboard = restoreRequested && target == .editable
        takesSnapshot = restoresClipboard
        sendsKeystroke = target != .notEditable
    }

    /// Where the warning about a displaced clipboard has to come from.
    ///
    /// A snapshot knows exactly what it failed to copy, so it gives the better message. With
    /// no snapshot there is still something to say, from the types the pasteboard advertises
    /// rather than a copy of its contents. Skipping the snapshot on those paths was right and
    /// taking the warning with it was not: a displaced image went silently where before it was
    /// at least reported.
    public var warningComesFromSnapshot: Bool { takesSnapshot }
}
