import Foundation

/// The writing style a message wants, decided by where it is going.
///
/// One case today. It is an enum rather than a boolean so a second style can be added
/// without changing the daemon protocol, where the raw value is what travels.
public enum MessageStyle: String {
    /// A chat app, where a typed message does not end in a full stop.
    case chat
}

/// Which apps count as chat.
///
/// Pure lookup, no AppKit, so the false positives that matter can be tested. The caller
/// supplies the frontmost bundle identifier and, only for a browser, its front window
/// title.
public enum ChatApps {
    /// Apps that are chat whatever window is open.
    ///
    /// Slack, Discord and Messages were read off the installed bundles. The WhatsApp and
    /// Teams identifiers are the published ones for apps not installed here, so they are the
    /// two entries that have not been confirmed against a running app.
    public static let bundleIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp",
        "desktop.WhatsApp",
        "com.microsoft.teams",
        "com.microsoft.teams2",
    ]

    /// Browsers, where the app identity says nothing and the window title is the only
    /// signal available without reading page content.
    public static let browserIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
    ]

    /// Titles a chat tab carries. Matched against a whole title segment, never as a
    /// substring, which is what keeps a page merely named after one of these out.
    static let titleMarkers: Set<String> = [
        "slack",
        "discord",
        "whatsapp",
        "whatsapp web",
        "messenger",
        "google chat",
        "microsoft teams",
    ]

    /// Whether this app needs its window title read before it can be classified.
    ///
    /// Worth asking separately because reading a title is an accessibility call into
    /// another process, which can block, while the bundle identifier is already in hand.
    public static func needsWindowTitle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return browserIdentifiers.contains(bundleIdentifier)
    }

    /// The style for what is in front, or nil when this is not a chat target.
    public static func style(bundleIdentifier: String?, windowTitle: String?) -> MessageStyle? {
        guard let bundleIdentifier else { return nil }
        if bundleIdentifiers.contains(bundleIdentifier) { return .chat }
        guard browserIdentifiers.contains(bundleIdentifier), let windowTitle else { return nil }
        return segments(of: windowTitle).contains(where: titleMarkers.contains) ? .chat : nil
    }

    /// Split a window title into the parts a site and a browser join it from.
    ///
    /// Only separators that a title is actually assembled with count: a pipe, a bullet, a
    /// long dash, and a hyphen with a space on both sides. A bare hyphen is deliberately not
    /// one, because "slack-notifier CI" is a repository name rather than two segments, and
    /// splitting on it would have read every page about Slack as Slack itself.
    ///
    /// An unread counter is stripped from the front. Chat tabs spend most of their life
    /// titled "(3) Slack", so leaving it on would mean the marker only ever matched a tab
    /// with nothing waiting in it.
    static func segments(of title: String) -> [String] {
        let separators: Set<Character> = ["|", "·", "•", "—", "–", "»"]
        let spacedHyphen = title.replacingOccurrences(of: " - ", with: "|")
        return spacedHyphen
            .split(whereSeparator: { separators.contains($0) })
            .map { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                let stripped = trimmed.replacingOccurrences(
                    of: "^\\(\\d+\\)\\s*", with: "", options: .regularExpression)
                return stripped.lowercased()
            }
            .filter { !$0.isEmpty }
    }
}
