import AppKit
import AVFoundation
import PhonaCore
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hud = HUDPanel()
    private let recorder = Recorder()
    private let hotkeys = HotkeyMonitor()
    private var levelTimer: Timer?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let permissions = PermissionState()
    private var tapInstalled = false

    /// Each hold gets an id. Results arrive asynchronously, so without this a slow result
    /// from the previous hold could tear down the HUD of the next one.
    private var session = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()

        hotkeys.onBegin = { [weak self] in self?.beginDictation() }
        hotkeys.onEnd = { [weak self] in self?.endDictation() }
        hotkeys.onAbort = { [weak self] in self?.abortDictation() }
        hotkeys.onToggleHandsFree = { [weak self] in self?.toggleHandsFree() }

        // Never block launch on a modal. Setup happens in its own window while the rest
        // of the app comes up, and the event tap is installed the moment the grant lands.
        DispatchQueue.global().async { DaemonClient.startAndWait() }

        if HotkeyMonitor.hasAccessibility(prompt: false) {
            tapInstalled = hotkeys.start()
            recorder.requestPermission { granted in
                if granted {
                    // Absorb the cold device open so the first hold is not truncated.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.recorder.warm() }
                } else {
                    self.showOnboarding()
                }
            }
        } else {
            Paths.log("accessibility not granted, showing setup")
            showOnboarding()
        }

        // Install the tap as soon as the user grants access, without needing a relaunch.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.tapInstalled, HotkeyMonitor.hasAccessibility(prompt: false) {
                self.tapInstalled = self.hotkeys.start()
                if self.tapInstalled { Paths.log("event tap installed after grant") }
            }
        }

        // Debug entry points, used to verify each window without clicking the menu bar.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openSettings() }
        }
        if CommandLine.arguments.contains("--probe-focus") {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Paths.log("focus probe: \(FocusProbe.describe())")
            }
        }
        if CommandLine.arguments.contains("--setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showOnboarding() }
        }

        // Check for a release once at launch and daily after that.
        UpdateCheck.check { version in
            if let version { Paths.log("update available: \(version)") }
        }
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            UpdateCheck.check()
        }

        // The system disables an event tap that ever times out. Put it back.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.hotkeys.reenableIfNeeded()
        }
    }

    // MARK: - Dictation

    private func beginDictation() {
        session += 1
        do {
            try recorder.start()
        } catch {
            Paths.log("start failed: \(error.localizedDescription)")
            notify("Phona", error.localizedDescription)
            hud.finish(.failed)
            return
        }
        hud.show(.listening)
        Cue.start.play()

        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.hud.model.level = self.recorder.level
        }
    }

    private func endDictation() {
        hotkeys.handsFree = false
        levelTimer?.invalidate()
        levelTimer = nil
        guard let take = recorder.stop() else { return }

        let mine = session
        hud.show(.working)
        Cue.stop.play()

        let minSeconds = 0.4
        guard take.seconds >= minSeconds else {
            try? FileManager.default.removeItem(at: take.url)
            Cue.nothing.play()
            hud.finish(.cancelled)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: take.url) }

            if !DaemonClient.isAlive() { DaemonClient.startAndWait() }
            let outcome = Result { try DaemonClient.process(url: take.url,
                                                            seconds: take.seconds,
                                                            mode: nil) }
            DispatchQueue.main.async {
                // Drop the result if another hold has started in the meantime.
                guard mine == self.session else { return }
                switch outcome {
                case .success(let result) where result.state == "done" && !result.text.isEmpty:
                    // Not every dictation should land in the focused app. Copy-only turns
                    // phona into a scratchpad without changing how you trigger it.
                    if Settings.insertAtCursor {
                        switch Paster.paste(result.text) {
                        case .pasted(let warning):
                            if let warning { self.notify("Phona", warning) }
                        case .leftOnClipboard(let reason):
                            // The text is safe on the clipboard. Say so rather than
                            // playing a success chime for text that went nowhere.
                            Paths.log("nowhere to paste, left on clipboard: \(reason)")
                            self.statusItem?.button?.toolTip =
                                "Your last dictation is on the clipboard. Press Cmd+V to place it."
                            Cue.nothing.play()
                            self.hud.finish(.clipboard)
                            return
                        }
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                    }
                    Cue.done.play()
                    self.hud.finish(.done)
                case .success(let result):
                    // The engine ran fine and simply had nothing to transcribe. Treat it
                    // as a cancel, not a failure, so an idle Option hold stays quiet.
                    Paths.log("nothing heard, state=\(result.state) raw=\(result.raw)")
                    Cue.nothing.play()
                    self.hud.finish(.cancelled)
                case .failure(let error):
                    Paths.log("daemon error: \(error.localizedDescription)")
                    self.notify("Phona", error.localizedDescription)
                    Cue.nothing.play()
                    self.hud.finish(.failed)
                }
            }
        }
    }

    /// Double tap Option to dictate without holding. Escape or a second double tap ends it.
    private func toggleHandsFree() {
        if hotkeys.handsFree {
            hotkeys.handsFree = false
            endDictation()
        } else {
            hotkeys.handsFree = true
            beginDictation()
        }
    }

    private func abortDictation() {
        hotkeys.handsFree = false
        session += 1
        levelTimer?.invalidate()
        levelTimer = nil
        recorder.cancel()
        hud.dismiss()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Phona")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let mode = Mode(rawValue: sender.title) else { return }
        mode.apply()
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Phona Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Flag the last dictation, and offer to capture what was actually said.
    ///
    /// The typed correction is optional on purpose. A click with no text still carries
    /// the signal that something was wrong, and demanding the exact wording would mean
    /// most bad dictations never get reported at all.
    @objc private func flagLastDictation() {
        let alert = NSAlert()
        alert.messageText = "Mark the last dictation as wrong"
        alert.informativeText = "Optionally type what you actually said. Leave it empty to "
            + "just flag it. Either way the audit will look at this one."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "what you actually said, optional"
        alert.accessoryView = field
        alert.addButton(withTitle: "Flag")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let actual = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global().async {
            var payload: [String: Any] = ["cmd": "FLAG"]
            if !actual.isEmpty { payload["actual"] = actual }
            _ = try? DaemonClient.request(payload, timeout: 20)
            Paths.log("flagged the last dictation, actual supplied: \(!actual.isEmpty)")
        }
    }

    @objc private func openReleases() { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
    @objc private func openHistory() { NSWorkspace.shared.open(Paths.history) }
    @objc private func openReadme() { NSWorkspace.shared.open(Paths.readme) }
    @objc private func warmMic() { recorder.warm() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func restartDaemon() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "phonad.py"]
        try? kill.run()
        kill.waitUntilExit()
        DispatchQueue.global().async { DaemonClient.startAndWait() }
    }

    @objc func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Phona Setup"
        window.contentView = NSHostingView(
            rootView: OnboardingView(state: permissions) { [weak self] in
                self?.onboardingWindow?.close()
            })
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Report a problem without stealing focus mid-dictation. The menu bar icon carries
    /// the detail, so a failed paste never throws a modal in front of what you were doing.
    private func notify(_ title: String, _ body: String) {
        Paths.log("\(title): \(body)")
        statusItem?.button?.toolTip = body
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let entries = HistoryEntry.recent()
        if entries.isEmpty {
            menu.addItem(withTitle: "No dictations yet", action: nil, keyEquivalent: "")
        } else {
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in entries {
                let trimmed = entry.text.count > 52
                    ? String(entry.text.prefix(51)) + "…"
                    : entry.text
                let item = NSMenuItem(title: "\(entry.clockTime)   \(trimmed)",
                                      action: #selector(copyEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "heard: \(entry.raw)"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let modeItem = NSMenuItem(title: "Correction mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        let current = Mode.current
        for mode in Mode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(chooseMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = mode == current ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())
        if let version = UpdateCheck.availableVersion {
            let item = NSMenuItem(title: "Update to \(version) is available",
                                  action: #selector(openReleases), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        add(menu, "Settings...", #selector(openSettings), key: ",")
        add(menu, "Setup and permissions...", #selector(showOnboarding))
        add(menu, "Mark last dictation as wrong...", #selector(flagLastDictation))
        add(menu, "Open history file", #selector(openHistory))
        add(menu, "Open README", #selector(openReadme))
        menu.addItem(.separator())
        add(menu, "Warm microphone", #selector(warmMic))
        add(menu, "Restart daemon", #selector(restartDaemon))
        menu.addItem(.separator())
        add(menu, "Quit Phona", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
}

// Headless render mode, used to review and regression-check the interface.
if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let dir = CommandLine.arguments.count > idx + 1
        ? URL(fileURLWithPath: CommandLine.arguments[idx + 1])
        : URL(fileURLWithPath: "/tmp/phona-previews")
    let renderApp = NSApplication.shared
    renderApp.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { Previews.renderAll(into: dir) }
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
