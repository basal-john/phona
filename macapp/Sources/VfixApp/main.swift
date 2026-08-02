import AppKit
import AVFoundation
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
        if CommandLine.arguments.contains("--setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showOnboarding() }
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
            notify("vfix", error.localizedDescription)
            hud.finish(success: false)
            return
        }
        hud.show(.listening)
        NSSound(named: "Tink")?.play()

        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.hud.model.level = self.recorder.level
        }
    }

    private func endDictation() {
        levelTimer?.invalidate()
        levelTimer = nil
        guard let take = recorder.stop() else { return }

        let mine = session
        hud.show(.working)
        NSSound(named: "Pop")?.play()

        let minSeconds = 0.4
        guard take.seconds >= minSeconds else {
            try? FileManager.default.removeItem(at: take.url)
            hud.finish(success: false)
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
                    if let warning = Paster.paste(result.text) {
                        self.notify("vfix", warning)
                    }
                    NSSound(named: "Glass")?.play()
                    self.hud.finish(success: true)
                case .success(let result):
                    Paths.log("no usable text, state=\(result.state) raw=\(result.raw)")
                    NSSound(named: "Basso")?.play()
                    self.hud.finish(success: false)
                case .failure(let error):
                    Paths.log("daemon error: \(error.localizedDescription)")
                    self.notify("vfix", error.localizedDescription)
                    NSSound(named: "Basso")?.play()
                    self.hud.finish(success: false)
                }
            }
        }
    }

    private func abortDictation() {
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
            systemSymbolName: "waveform", accessibilityDescription: "vfix")
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
        window.title = "vfix Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHistory() { NSWorkspace.shared.open(Paths.history) }
    @objc private func openReadme() { NSWorkspace.shared.open(Paths.readme) }
    @objc private func warmMic() { recorder.warm() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func restartDaemon() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "vfixd.py"]
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
        window.title = "vfix Setup"
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
        add(menu, "Settings...", #selector(openSettings), key: ",")
        add(menu, "Setup and permissions...", #selector(showOnboarding))
        add(menu, "Open history file", #selector(openHistory))
        add(menu, "Open README", #selector(openReadme))
        menu.addItem(.separator())
        add(menu, "Warm microphone", #selector(warmMic))
        add(menu, "Restart daemon", #selector(restartDaemon))
        menu.addItem(.separator())
        add(menu, "Quit vfix", #selector(quit), key: "q")
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
        : URL(fileURLWithPath: "/tmp/vfix-previews")
    let renderApp = NSApplication.shared
    renderApp.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { Previews.renderAll(into: dir) }
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
