import AppKit
import ApplicationServices
import PhonaCore

/// Reads what is in front, so the daemon can style a message for where it is going.
///
/// The daemon cannot see the screen, and the app can, so the classification happens here and
/// travels with the request. It is read when the hotkey goes down rather than when the text
/// comes back, because that is the app the speaker was talking into, and a slow dictation can
/// outlive the window that started it.
enum AppContext {
    /// The style for the frontmost app, or nil when it is not a chat target.
    ///
    /// Never call this on the main thread. `frontmostApplication` is cheap, but the window
    /// title behind it is an accessibility call into another process, and the whole reason
    /// the HUD appears in 9 ms is that nothing blocking runs on the way to the first frame.
    static func currentStyle() -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier
        var title: String?
        if ChatApps.needsWindowTitle(bundle) {
            title = frontWindowTitle(pid: app?.processIdentifier)
        }
        return ChatApps.style(bundleIdentifier: bundle, windowTitle: title)?.rawValue
    }

    /// What the style decision saw and what it decided, for `--probe-style`.
    ///
    /// The classification is worth being able to watch on a real machine. Whether a browser
    /// reports its window title over accessibility is not something a unit test can answer,
    /// and without this the only way to find out was to dictate and inspect the punctuation.
    static func describe() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier ?? "unknown"
        var title = "not read"
        if ChatApps.needsWindowTitle(app?.bundleIdentifier) {
            title = frontWindowTitle(pid: app?.processIdentifier) ?? "accessibility said nothing"
        }
        return "\(bundle), title \"\(title)\", style \(currentStyle() ?? "none")"
    }

    /// The title of an app's focused window, or nil when accessibility will not say.
    ///
    /// A browser that reports nothing is treated as not chat, which errs toward leaving
    /// punctuation alone. Guessing the other way would strip a full stop from a document.
    private static func frontWindowTitle(pid: pid_t?) -> String? {
        guard let pid else { return nil }
        let app = AXUIElementCreateApplication(pid)

        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let focused = window as! AXUIElement?
        else { return nil }

        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}
