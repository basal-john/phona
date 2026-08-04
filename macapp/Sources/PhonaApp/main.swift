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

    /// Serialises opening, stopping and cancelling the device, so a release that arrives while
    /// the device is still opening cannot race the open. Everything that blocks for longer than
    /// a frame runs here rather than on the main thread, because the main thread is what draws.
    private let audioQueue = DispatchQueue(label: "com.basalona.phona.audio")

    /// `--trace-timing` logs how long each stage of a dictation took.
    ///
    /// It exists because three attempts at a latency problem were made without one, each
    /// guessing at a stage rather than measuring it, and the one set of numbers that did get
    /// collected was thrown away afterwards. The stages are what the speaker waits through, and
    /// the daemon's own transcription and correction figures are folded in so the whole span is
    /// attributed in one place.
    private lazy var tracing = CommandLine.arguments.contains("--trace-timing")

    /// When the key came up, so every tail stage is reported against the moment the speaker
    /// stopped talking rather than against the previous stage.
    private var releasedAt: CFAbsoluteTime?

    private func trace(_ stage: String, since start: CFAbsoluteTime) {
        guard tracing else { return }
        Paths.log(String(format: "tail: %@ at %.0f ms", stage,
                         (CFAbsoluteTimeGetCurrent() - start) * 1000))
    }

    /// Each hold gets an id. Results arrive asynchronously, so without this a slow result
    /// from the previous hold could tear down the HUD of the next one.
    private var session = 0

    /// Bring the app up without ever blocking on a permission dialog.
    ///
    /// Accepts two debug flags, `--probe-focus` and `--setup`, which open a window or log
    /// the focus target without needing the menu bar.
    ///
    /// Setup happens in its own window while the rest of the app starts, the event tap is
    /// installed the moment the grant lands rather than on the next launch, and the
    /// microphone is opened once to absorb the cold device open, which otherwise truncates
    /// the first dictation after boot. The tap is re-enabled on a timer because the system
    /// disables any event tap that times out.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()

        hotkeys.onBegin = { [weak self] in self?.beginDictation() }
        hotkeys.onEnd = { [weak self] in self?.endDictation() }
        hotkeys.onAbort = { [weak self] in self?.abortDictation() }
        hotkeys.onToggleHandsFree = { [weak self] in self?.toggleHandsFree() }

        DispatchQueue.global().async { DaemonClient.startAndWait() }

        if HotkeyMonitor.hasAccessibility(prompt: false) {
            tapInstalled = hotkeys.start()
            recorder.requestPermission { granted in
                if granted {
                    self.audioQueue.asyncAfter(deadline: .now() + 1.5) { self.recorder.warm() }
                } else {
                    self.showOnboarding()
                }
            }
        } else {
            Paths.log("accessibility not granted, showing setup")
            showOnboarding()
        }

        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.tapInstalled, HotkeyMonitor.hasAccessibility(prompt: false) {
                self.tapInstalled = self.hotkeys.start()
                if self.tapInstalled { Paths.log("event tap installed after grant") }
            }
        }

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

        UpdateCheck.check { version in
            if let version { Paths.log("update available: \(version)") }
        }
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            UpdateCheck.check()
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.hotkeys.reenableIfNeeded()
        }
    }

    // MARK: - Dictation

    /// Show the HUD, then open the device somewhere else.
    ///
    /// Nothing is drawn until this function returns to the run loop, so any blocking work left
    /// in it holds the HUD off screen no matter where the statements sit. That is the whole
    /// reason the HUD felt slow, and it is why reordering alone changed nothing. Measured: 9 ms
    /// to the first frame with nothing blocking afterwards, 326 ms with 324 ms of blocking work
    /// afterwards, and `hud.show()` itself returns in under a millisecond because it only
    /// assigns state.
    ///
    /// Both blocking calls are now off the main thread. `Cue.play()` does it internally, since
    /// it blocks while the output device wakes, up to 796 ms. Opening the input device costs
    /// 110 ms warm and over a second cold, and runs on `audioQueue`, which serialises it
    /// against the stop and cancel that may arrive while it is still opening.
    ///
    /// The waveform idles until the first buffer lands, because a flat waveform and a waveform
    /// with nothing behind it look identical.
    private func beginDictation() {
        session += 1
        let mine = session
        hud.show(.listening)
        Cue.start.play()
        startLevelTimer()
        let armed = CFAbsoluteTimeGetCurrent()
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.recorder.start()
                self.trace("device open", since: armed)
            } catch {
                DispatchQueue.main.async {
                    guard mine == self.session else { return }
                    Paths.log("start failed: \(error.localizedDescription)")
                    self.notify("Phona", error.localizedDescription)
                    self.levelTimer?.invalidate()
                    self.levelTimer = nil
                    self.hud.finish(.failed)
                }
            }
        }
    }

    /// Drive the waveform, and tell the HUD when there is genuinely audio to draw.
    ///
    /// An earlier version drew a synthetic pulse while waiting for the device, to stop a flat
    /// line reading as broken. It read as listening instead, so speech started before the
    /// microphone was open and the first word was lost. The bars now stay dim and still until
    /// the first buffer arrives, which is the honest signal and also the useful one.
    private func startLevelTimer() {
        levelTimer?.invalidate()
        let armed = CFAbsoluteTimeGetCurrent()
        var announced = false
        hud.model.capturing = false
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let live = self.recorder.hasAudio
            if live, !announced {
                announced = true
                self.trace("first audio buffer", since: armed)
            }
            self.hud.model.capturing = live
            self.hud.model.level = live ? self.recorder.level : 0
        }
    }

    /// Stop recording, transcribe, and deliver the result.
    ///
    /// Each hold carries an id, because a slow result from the previous hold would
    /// otherwise tear down the HUD of the next one. Where the text goes depends on the
    /// output setting: inserting is the default, and copy-only turns dictation into a
    /// scratchpad without changing how it is triggered. Text that had nowhere to land is
    /// reported rather than chimed for, and a recording that simply contained no speech is
    /// treated as a cancel rather than a failure, so an idle Option hold stays quiet.
    private func endDictation() {
        hotkeys.handsFree = false
        levelTimer?.invalidate()
        levelTimer = nil

        let mine = session
        hud.show(.working)
        Cue.stop.play()
        let released = CFAbsoluteTimeGetCurrent()
        releasedAt = released

        audioQueue.async { [weak self] in
            guard let self else { return }
            let take = self.recorder.stop()
            self.trace("device closed", since: released)
            DispatchQueue.main.async {
                guard mine == self.session else {
                    if let take { try? FileManager.default.removeItem(at: take.url) }
                    return
                }
                guard let take else {
                    /// Nothing to stop, so the open must have failed. The HUD is already showing
                    /// "working" by this point and would otherwise sit there for good.
                    Paths.log("nothing to stop, the device never opened")
                    self.hud.finish(.cancelled)
                    return
                }
                self.deliver(take, session: mine)
            }
        }
    }

    /// Transcribe a finished take and put the result where the settings say.
    ///
    /// Split out from `endDictation` because stopping the device now happens on `audioQueue`,
    /// so the take arrives back here asynchronously rather than being in hand already.
    private func deliver(_ take: (url: URL, seconds: Double), session mine: Int) {
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
            if let released = self.releasedAt { self.trace("daemon request sent", since: released) }
            let outcome = Result { try DaemonClient.process(url: take.url,
                                                            seconds: take.seconds,
                                                            mode: nil) }
            if let released = self.releasedAt, case .success(let r) = outcome {
                self.trace(String(format: "daemon replied, its own stt %.2fs llm %.2fs",
                                  r.sttSeconds, r.llmSeconds), since: released)
            }
            DispatchQueue.main.async {
                guard mine == self.session else { return }
                switch outcome {
                case .success(let result) where result.state == "done" && !result.text.isEmpty:
                    if Settings.insertAtCursor {
                        switch Paster.paste(result.text) {
                        case .pasted(let warning):
                            if let warning { self.notify("Phona", warning) }
                        case .leftOnClipboard(let reason):
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
                    if let released = self.releasedAt { self.trace("pasted", since: released) }
                    self.hud.finish(.done)
                case .success(let result):
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
        audioQueue.async { [weak self] in self?.recorder.cancel() }
        hud.dismiss()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarMark()
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    /// The app mark, Φ, drawn for the menu bar.
    ///
    /// Drawn here rather than bundled as an image so it stays sharp on any display and needs
    /// no resource to be copied into the bundle, and drawn at all because the menu bar used
    /// the `waveform` system symbol, which is the generic audio glyph and belongs to no
    /// product. Marked as a template, so macOS tints it for the light or dark menu bar and it
    /// follows the highlight when the menu is open.
    ///
    /// The proportions are the icon's, opened up: with no slab to sit inside, the letter fills
    /// its frame, and the stroke stays at 1.5 pt because anything finer disappears against a
    /// light menu bar.
    private static func menuBarMark() -> NSImage {
        let side: CGFloat = 15
        let stroke: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let radius = side * 0.29
            let bowl = NSBezierPath(ovalIn: NSRect(x: rect.midX - radius, y: rect.midY - radius,
                                                   width: radius * 2, height: radius * 2))
            bowl.lineWidth = stroke
            bowl.stroke()

            let height = side * 0.88
            let stem = NSBezierPath(
                roundedRect: NSRect(x: rect.midX - stroke / 2, y: rect.midY - height / 2,
                                    width: stroke, height: height),
                xRadius: stroke / 2, yRadius: stroke / 2)
            stem.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Phona"
        return image
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
    @objc private func warmMic() {
        audioQueue.async { [weak self] in self?.recorder.warm() }
    }
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
                /// A corrected entry can be a multi-line list, and a newline in a menu item
                /// title breaks the row's single-line shape. The full text is still what
                /// gets copied, so only the preview is flattened.
                let flat = entry.text.split(whereSeparator: \.isNewline)
                    .joined(separator: " ")
                let trimmed = flat.count > 52
                    ? String(flat.prefix(51)) + "…"
                    : flat
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
