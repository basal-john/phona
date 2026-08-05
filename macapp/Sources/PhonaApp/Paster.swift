import AppKit
import Foundation
import PhonaCore

enum Paths {
    static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/phona")
    static let python = base.appendingPathComponent("venv/bin/python")
    static let daemon = base.appendingPathComponent("phonad.py")
    static let config = base.appendingPathComponent("config.json")
    static let history = base.appendingPathComponent("history.jsonl")
    static let readme = base.appendingPathComponent("README.md")
    static let log = base.appendingPathComponent("app.log")

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: log) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: log)
            }
        }
    }
}

/// Puts text where the cursor is.
enum Paster {
    enum Outcome {
        /// Inserted at the cursor, and the previous clipboard was put back.
        case pasted(warning: String?)
        /// Nothing editable was focused, so the text was left on the clipboard for the
        /// user to place themselves. Never silently discarded.
        case leftOnClipboard(reason: String)
    }

    /// Deliver the text, and never lose it.
    ///
    /// Pasting cannot be verified. Posting Cmd+V reports that the event was sent, not that
    /// anything consumed it, so a dictation delivered with nothing focused used to vanish
    /// twice over: the keystroke went nowhere and the clipboard restore then overwrote the
    /// text. The user heard a success chime for text that survived only in the history.
    ///
    /// So the clipboard is only restored when Accessibility confirms an editable target.
    /// Anywhere else the dictation stays on the clipboard, which is recoverable with one
    /// Cmd+V, and the caller is told so it can say as much.
    ///
    /// A confirmed non-target gets no keystroke at all, because in Finder Cmd+V means paste
    /// a file, which would either do nothing or do something unwanted.
    ///
    /// The whole clipboard is copied, not only its text. An earlier version snapshotted
    /// `.string` alone, so a dictation taken while an image was on the clipboard destroyed
    /// the image and said so afterwards, which it did seventeen times in one log. The care
    /// taken never to lose the dictation has to extend to what the dictation displaces.
    ///
    /// It is copied only when it is going to be put back. Reading every representation of every
    /// item is not free: an item waiting on Universal Clipboard sends the read looking for
    /// another device, and an image is megabytes. Neither belongs on the paste path when the
    /// setting deliberately keeps the dictation on the clipboard, or when Accessibility could
    /// not confirm a target and the dictation is being left there on purpose. Nothing is
    /// promised in those cases, so nothing is warned about either.
    @discardableResult
    static func paste(_ text: String, restore: Bool = true) -> Outcome {
        let board = NSPasteboard.general
        let target = FocusProbe.current()

        let willRestore = restore && target == .editable
        let snapshot = willRestore ? ClipboardStore.snapshot(of: board) : .notTaken
        let warning = snapshot.warning

        board.clearContents()
        board.setString(text, forType: .string)

        if target == .notEditable {
            return .leftOnClipboard(reason: FocusProbe.describe())
        }

        guard sendCommandV() else {
            return .leftOnClipboard(reason: "the paste keystroke could not be sent")
        }

        if willRestore, snapshot.canRestore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                /// Only when the dictation is still there. Anything else means the user
                /// copied something in the meantime, and that is theirs, not ours to undo.
                if board.string(forType: .string) == text {
                    ClipboardStore.restore(snapshot, to: board)
                }
            }
        }
        return .pasted(warning: warning)
    }

    private static func sendCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

/// One dictation, as stored by the daemon.
struct HistoryEntry {
    let timestamp: String
    let raw: String
    let text: String

    var clockTime: String {
        guard timestamp.count >= 16 else { return timestamp }
        let start = timestamp.index(timestamp.startIndex, offsetBy: 11)
        let end = timestamp.index(timestamp.startIndex, offsetBy: 16)
        return String(timestamp[start..<end])
    }

    static func recent(limit: Int = 12) -> [HistoryEntry] {
        guard let content = try? String(contentsOf: Paths.history, encoding: .utf8) else {
            return []
        }
        let lines = content.split(separator: "\n").suffix(limit)
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return HistoryEntry(
                timestamp: obj["ts"] as? String ?? "",
                raw: obj["raw"] as? String ?? "",
                text: obj["text"] as? String ?? ""
            )
        }.reversed()
    }
}

/// App-side settings that the daemon does not need to know about.
enum Settings {
    private static func value<T>(_ key: String, default fallback: T) -> T {
        guard let data = try? Data(contentsOf: Paths.config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj[key] as? T
        else { return fallback }
        return v
    }

    static var outputAction: OutputAction {
        OutputAction.from(configValue: value("output_action", default: "insert"))
    }

    /// Whether Phona keeps a Dock icon as well as its menu bar item.
    static var showInDock: Bool { value("show_in_dock", default: true) }

    /// Whether the output device is muted while the microphone is capturing.
    static var muteOthersWhileDictating: Bool { value("mute_others", default: true) }

    /// Whether a message dictated into a chat app drops its closing full stop.
    ///
    /// App-side rather than an engine setting, even though the daemon does the work, because
    /// the daemon only ever acts on a style the app chose to send. Turning this off stops it
    /// being sent, so it takes effect on the next hold instead of on the next restart.
    static var casualInChat: Bool { value("casual_in_chat", default: true) }

    /// Write one key without disturbing the rest of the file.
    ///
    /// Separate from the settings window's save, which restarts the engine because the keys
    /// it writes are prefilled into the daemon's prompt at startup. These two are the app's
    /// own behaviour, the daemon never reads them, and restarting a model load to move a
    /// Dock icon would be absurd.
    static func set(_ key: String, _ newValue: Any) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.config),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj[key] = newValue
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Paths.config)
    }
}

/// Correction mode, read from and written to the same config.json the daemon uses.
enum Mode: String, CaseIterable {
    case grammar, polish, raw

    static var current: Mode {
        guard let data = try? Data(contentsOf: Paths.config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj["mode"] as? String,
              let mode = Mode(rawValue: value)
        else { return .grammar }
        return mode
    }

    /// Persist and restart the daemon, since the prompt prefix is prefilled per mode.
    func apply() {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.config),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj["mode"] = rawValue
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.config)
        }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "phonad.py"]
        try? kill.run()
        kill.waitUntilExit()
        DispatchQueue.global().async { DaemonClient.startAndWait() }
    }
}
