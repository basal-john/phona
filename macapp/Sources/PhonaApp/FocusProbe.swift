import AppKit
import ApplicationServices

/// Works out whether there is somewhere for text to land.
///
/// This exists because pasting is unverifiable. Posting Cmd+V reports only that the event
/// was sent, never that anything consumed it, so a dictation delivered with nothing focused
/// used to vanish: the keystroke went nowhere and the clipboard restore then overwrote the
/// text. The user got a success chime for text that existed only in the history file.
enum FocusProbe {
    enum Target {
        /// An editable element is focused. Pasting will land, and the clipboard can safely
        /// be put back afterwards.
        case editable
        /// Something is focused but it does not take text, or nothing is focused at all.
        case notEditable
        /// Accessibility could not tell us. Common in apps that expose little of their
        /// hierarchy, so this must not be treated as a failure.
        case unknown
    }

    /// Roles that accept typed text. Web areas and groups are included because browsers
    /// and Electron apps often report a container rather than the field itself.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXWebArea",
        "AXSearchField",
    ]

    /// Classify where text would land right now.
    ///
    /// No focused element at all is a real answer rather than an unknown one, since that is
    /// what the Desktop and an unselected window look like. A custom role that still exposes
    /// a settable value counts as editable, because that is the more reliable of the two
    /// signals.
    static func current() -> Target {
        let system = AXUIElementCreateSystemWide()

        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
            let app = focusedApp as! AXUIElement?
        else { return .unknown }

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused)

        if status == .noValue || status == .attributeUnsupported {
            return .notEditable
        }
        guard status == .success, let element = focused as! AXUIElement? else {
            return .unknown
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        if editableRoles.contains(role) {
            return .editable
        }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return .editable
        }

        return role.isEmpty ? .unknown : .notEditable
    }

    /// A short description of where the text would go, for the log.
    static func describe() -> String {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown app"
        switch current() {
        case .editable: return "editable target in \(app)"
        case .notEditable: return "no editable target in \(app)"
        case .unknown: return "target unknown in \(app)"
        }
    }
}
