import Foundation

/// Where a finished dictation goes.
///
/// Insert mode already routes through the clipboard: it copies the text, sends Cmd+V, then
/// puts the previous contents back. So `both` is not a third delivery mechanism, it is insert
/// without that final restore, which leaves the dictation on the clipboard for Universal
/// Clipboard to carry to another device.
///
/// The raw values are the strings stored in `config.json` under `output_action`, so this
/// enum is the single place the spelling of those three values lives.
public enum OutputAction: String, CaseIterable {
    case insert
    case clipboard
    case both

    /// Unknown and missing values fall back to inserting, which is the default a fresh
    /// install runs with. A config written by a newer version must not silently become
    /// clipboard-only on an older one, because that would stop text reaching the cursor
    /// with no indication why.
    public static func from(configValue: String?) -> OutputAction {
        OutputAction(rawValue: configValue ?? "") ?? .insert
    }

    /// Whether the text is typed where the cursor is.
    public var insertsAtCursor: Bool { self != .clipboard }

    /// Whether the dictation is left on the clipboard rather than the previous contents
    /// being restored.
    public var keepsOnClipboard: Bool { self == .both }
}
