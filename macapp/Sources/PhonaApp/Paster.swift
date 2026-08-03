import AppKit
import Foundation

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
    @discardableResult
    static func paste(_ text: String, restore: Bool = true) -> Outcome {
        let board = NSPasteboard.general
        let target = FocusProbe.current()

        let hadItems = !(board.pasteboardItems ?? []).isEmpty
        let previous = board.string(forType: .string)
        var warning: String?
        if restore, previous == nil, hadItems {
            warning = "Your clipboard held an image or file. It has been replaced and cannot be restored."
        }

        board.clearContents()
        board.setString(text, forType: .string)

        if target == .notEditable {
            // Do not fire a keystroke into something that cannot take it. In Finder for
            // instance Cmd+V means paste a file, which would either do nothing or do
            // something unwanted.
            return .leftOnClipboard(reason: FocusProbe.describe())
        }

        guard sendCommandV() else {
            return .leftOnClipboard(reason: "the paste keystroke could not be sent")
        }

        // Restoring is only safe where the paste almost certainly landed. When the target
        // is unknown the text stays on the clipboard, because losing a dictation is worse
        // than leaving a clipboard changed.
        if restore, target == .editable, let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if board.string(forType: .string) == text {
                    board.clearContents()
                    board.setString(previous, forType: .string)
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

    static var insertAtCursor: Bool { value("output_action", default: "insert") == "insert" }
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
