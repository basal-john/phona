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
    private var onboardingWindow: NSWindow?
    private var mainWindow: NSWindow?

    /// Held on the delegate rather than inside the window's view, because the reload trigger
    /// is the window becoming key and only a window delegate can see that.
    private let historyStore = HistoryStore()

    /// What the window is showing.
    ///
    /// Owned here rather than inside `MainWindowView`, because the pane and the history
    /// filter both need to be menu commands. A toolbar can be hidden or customised, so it
    /// may not be the only route to a command, and a `@State` inside the view is reachable
    /// from no menu at all.
    private let windowModel = WindowModel()
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

    /// The style of the app that was in front when a hold started, tagged with that hold.
    ///
    /// Tagged rather than stored plainly because it is written from a background queue and
    /// read from another one, and an untagged value would let a slow read from the previous
    /// hold style this one. Guarded by a lock for the same reason: `session` itself is only
    /// ever touched on the main thread, so it cannot be consulted from either side.
    private var styleForSession: (session: Int, style: String)?
    private let styleLock = NSLock()

    private func rememberStyle(_ style: String?, session: Int) {
        styleLock.lock()
        defer { styleLock.unlock() }
        if let styleForSession, styleForSession.session > session { return }
        styleForSession = style.map { (session, $0) }
    }

    private func style(forSession wanted: Int) -> String? {
        styleLock.lock()
        defer { styleLock.unlock() }
        guard let styleForSession, styleForSession.session == wanted else { return nil }
        return styleForSession.style
    }

    /// Which Option key started each hold, tagged with that hold and locked for the same
    /// reason `styleForSession` is: it is written on the main thread when the key goes down
    /// and read from `deliver`'s queue when the text comes back.
    private var cloudForSession: (session: Int, cloud: Bool)?

    private func rememberCloud(_ cloud: Bool, session: Int) {
        styleLock.lock()
        defer { styleLock.unlock() }
        if let cloudForSession, cloudForSession.session > session { return }
        cloudForSession = (session, cloud)
    }

    /// The correction mode for a hold, or nil for the local model.
    ///
    /// Defaults to the local model when the tag does not match, so a hold whose record was
    /// overtaken is cleaned the way it is cleaned today rather than sent to the cloud.
    private func mode(forSession wanted: Int) -> String? {
        styleLock.lock()
        defer { styleLock.unlock() }
        guard let cloudForSession, cloudForSession.session == wanted else { return nil }
        return cloudForSession.cloud ? "cloud" : nil
    }

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
        NSApp.setActivationPolicy(Settings.showInDock ? .regular : .accessory)
        OutputMute.recoverFromInterruptedDictation()
        buildMainMenu()
        buildStatusItem()

        hotkeys.probing = CommandLine.arguments.contains("--probe-hotkey")
        hotkeys.onBegin = { [weak self] cloud in self?.beginDictation(cloud: cloud) }
        hotkeys.onEnd = { [weak self] in self?.endDictation() }
        hotkeys.onAbort = { [weak self] in self?.abortDictation() }

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
        if CommandLine.arguments.contains("--probe-style") {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                DispatchQueue.global(qos: .utility).async {
                    Paths.log("style probe: \(AppContext.describe())")
                }
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

        sweepAbandonedTakes()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.sweepAbandonedTakes()
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
    private func beginDictation(cloud: Bool = false) {
        session += 1
        let mine = session
        rememberCloud(cloud, session: mine)
        hud.show(.listening)
        Cue.start.play()
        startLevelTimer()
        let armed = CFAbsoluteTimeGetCurrent()
        if Settings.casualInChat {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.rememberStyle(AppContext.currentStyle(), session: mine)
            }
        } else {
            rememberStyle(nil, session: mine)
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.recorder.start()
                self.trace("device open", since: armed)
            } catch {
                DispatchQueue.main.async {
                    guard mine == self.session else { return }
                    Paths.log("start failed: \(error.localizedDescription)")
                    self.levelTimer?.invalidate()
                    self.levelTimer = nil
                    OutputMute.release()
                    /// The wav is created before the engine is started, so a failure part way
                    /// through `start` leaves a file nothing else will ever claim.
                    self.audioQueue.async { self.recorder.cancel() }
                    self.fail(error.localizedDescription)
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
                OutputMute.engage()
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
    /// treated as a cancel rather than a failure, so a tap that caught no speech stays quiet.
    private func endDictation() {
        levelTimer?.invalidate()
        levelTimer = nil
        OutputMute.release()

        let mine = session
        hud.show(mode(forSession: mine) == "cloud" ? .workingInCloud : .working)
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

        /// A take that ran its full length without a single buffer means the capture layer is
        /// dead, not that the speaker was quiet. It looked like an ordinary empty dictation
        /// for an hour while coreaudiod sat wedged, and the only evidence was a 4 kB wav with
        /// no frames in it.
        ///
        /// It has to come after the length check, not before. The first buffer arrives around
        /// 450 ms after the device opens, so every hold shorter than that has captured nothing
        /// yet through no fault of the microphone. Asked first, this told anyone who tapped
        /// Option that their microphone was dead.
        guard recorder.capturedAnyAudio else {
            try? FileManager.default.removeItem(at: take.url)
            Paths.log("the microphone delivered no audio for the whole take")
            fail("The microphone delivered no audio. Check the input level in System "
                 + "Settings, Sound. If it is dead there too, restart Core Audio.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: take.url) }

            if !DaemonClient.isAlive() { DaemonClient.startAndWait() }
            if let released = self.releasedAt { self.trace("daemon request sent", since: released) }

            /// A local reply lands in 1-5s. Past that, a HUD stuck on "working" with no other
            /// signal reads as broken rather than slow, which is what "the output never came"
            /// turned out to mean on 2026-09-01: the daemon was still alive, just tens of
            /// seconds slower than usual under memory pressure from an unrelated process. This
            /// does not change when or whether the result arrives, only whether the wait during
            /// it is legible, so a still-slow request after this one keeps working the same way,
            /// just with something to check.
            ///
            /// The cloud correction moves both numbers. Measured on real dictations it takes
            /// 7-20s, so the local 8s deadline would fire on every single one of them and
            /// call an expected wait "longer than usual", which is how a notice stops meaning
            /// anything. The right Option key gets its own deadline past its normal range and
            /// wording that says what is being waited for rather than that something is wrong.
            let cloud = self.mode(forSession: mine) == "cloud"
            let stillWorkingNotice = cloud
                ? "Still working. The cloud model usually takes 7-20 seconds."
                : "Still working. This dictation is taking longer than usual."
            let slowAfter: Double = cloud ? 25 : 8
            let slowNotice = DispatchWorkItem { [weak self] in
                guard let self, mine == self.session else { return }
                /// Never clobber a tooltip already there, ours or a warning from an earlier
                /// dictation waiting to be read (see the matching guard below on clear).
                guard self.statusItem?.button?.toolTip == nil else { return }
                self.statusItem?.button?.toolTip = stillWorkingNotice
                Paths.log("dictation still running past \(Int(slowAfter))s, "
                          + (cloud ? "longer than the usual 7-20s for the cloud model"
                                   : "longer than the usual 1-5s"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + slowAfter, execute: slowNotice)

            let outcome = Result { try DaemonClient.process(url: take.url,
                                                            seconds: take.seconds,
                                                            mode: self.mode(forSession: mine),
                                                            style: self.style(forSession: mine)) }
            slowNotice.cancel()
            if let released = self.releasedAt, case .success(let r) = outcome {
                self.trace(String(format: "daemon replied, its own stt %.2fs llm %.2fs",
                                  r.sttSeconds, r.llmSeconds), since: released)
            }
            DispatchQueue.main.async {
                guard mine == self.session else { return }
                /// Only clear a tooltip this dictation set. A warning from an earlier one
                /// (the clipboard-restore notice `notify` leaves behind) is meant to survive
                /// until read, per `clearFailureMark`'s own comment on the sibling mark.
                if self.statusItem?.button?.toolTip == stillWorkingNotice {
                    self.statusItem?.button?.toolTip = nil
                }
                switch outcome {
                case .success(let result) where result.state == "done" && !result.text.isEmpty:
                    /// Anything that delivers text clears the mark, not only a clean result.
                    /// Left to the clean branch alone, one failure stuck to the menu bar
                    /// through every later dictation that went to the clipboard or was
                    /// trimmed, which is most of them for anyone who hits either often.
                    self.clearFailureMark()
                    let action = Settings.outputAction
                    if action.insertsAtCursor {
                        switch Paster.paste(result.text, restore: !action.keepsOnClipboard) {
                        case .pasted(let warning):
                            if let warning { self.notify("Phona", warning) }
                        case .leftOnClipboard(let reason, let warning):
                            Paths.log("nowhere to paste, left on clipboard: \(reason)")
                            /// The clipboard was replaced before this path was taken, so
                            /// whatever it displaced is gone whether or not the paste landed.
                            if let warning { self.notify("Phona", warning) }
                            self.statusItem?.button?.toolTip =
                                "Your last dictation is on the clipboard. Press Cmd+V to place it."
                            Cue.nothing.play()
                            self.hud.finish(.clipboard)
                            return
                        }
                    } else if let warning = Paster.copyToClipboard(result.text) {
                        self.notify("Phona", warning)
                    }
                    if let released = self.releasedAt { self.trace("pasted", since: released) }
                    if result.trimmedWords > 0 {
                        /// Delivered, but shorter than what was said. The quiet cue rather than
                        /// the completion chime, so the ear is told as well as the eye.
                        Paths.log("trimmed \(result.trimmedWords) repeated words off the end")
                        self.statusItem?.button?.toolTip =
                            "Your last dictation looped. \(result.trimmedWords) repeated words "
                            + "were cut off the end, so it may be short. What was heard, tail "
                            + "and all, is the raw field of the last history.jsonl line."
                        Cue.nothing.play()
                        self.hud.finish(.trimmed)
                    } else {
                        Cue.done.play()
                        self.hud.finish(.done)
                    }
                case .success(let result):
                    Paths.log("nothing heard, state=\(result.state) raw=\(result.raw)")
                    Cue.nothing.play()
                    self.hud.finish(.cancelled)
                case .failure(let error):
                    Paths.log("daemon error: \(error.localizedDescription)")
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func abortDictation() {
        session += 1
        levelTimer?.invalidate()
        levelTimer = nil
        OutputMute.release()
        audioQueue.async { [weak self] in self?.recorder.cancel() }
        hud.dismiss()
    }

    /// Opening the app shows the window, not the settings.
    ///
    /// Clicking the Dock icon of an already-running app calls this, and doing nothing here
    /// is what made the icon look dead: Phona keeps no window open between uses, so there
    /// was nothing for macOS to bring forward and no handler to open anything.
    ///
    /// It opened Settings, which predates there being a window to open. Once one existed the
    /// only routes to it were the menu bar item and Cmd-0, so the gesture that means "show
    /// me Phona" answered with the preferences pane. Reported three times as still seeing
    /// the old UI, which is what it looks like: the settings pane is unchanged since before
    /// the window existed, so an app that opens it appears not to have updated at all.
    ///
    /// Settings keeps its own menu item and its own Cmd-comma, which is where a preferences
    /// pane belongs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    /// Quitting with a dictation in flight must not leave the Mac silent.
    func applicationWillTerminate(_ notification: Notification) {
        OutputMute.release()
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

    /// Show the settings pane.
    ///
    /// Settings used to be a window of its own, built here the way `openMainWindow` builds
    /// the main one. It is a pane of the main window now, so this selects it rather than
    /// opening a second copy of the same form. The App menu keeps its item and
    /// Command-comma keeps working, which is what anyone reaching for either expects.
    @objc private func openSettings() {
        windowModel.pane = .settings
        openMainWindow()
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
        DispatchQueue.global().async { [weak self] in
            var payload: [String: Any] = ["cmd": "FLAG"]
            if !actual.isEmpty { payload["actual"] = actual }
            let problem = AppDelegate.flagProblem(payload)
            Paths.log("flagged the last dictation, actual supplied: \(!actual.isEmpty), "
                + "accepted: \(problem == nil)")
            DispatchQueue.main.async {
                guard let self else { return }
                if let problem {
                    self.reportFlagFailure(problem)
                } else {
                    self.historyStore.reload()
                }
            }
        }
    }

    /// Why the daemon did not record the flag, or nil when it did.
    ///
    /// Every one of these is something the speaker can act on: a daemon that is not running,
    /// a socket that timed out, a history file with nothing in it yet. Dropping them left the
    /// button looking like it had worked, on the one feature in the app that collects ground
    /// truth, so a flag nobody knows was lost is a correction nobody types again.
    private static func flagProblem(_ payload: [String: Any]) -> String? {
        let reply: [String: Any]
        do {
            reply = try DaemonClient.request(payload, timeout: 20)
        } catch {
            return "The engine did not answer. \(error.localizedDescription)"
        }
        if (reply["state"] as? String) == "done" { return nil }
        if let detail = reply["error"] as? String, !detail.isEmpty {
            return "The engine refused the flag. \(detail)"
        }
        return "The engine answered without recording the flag."
    }

    /// A modal rather than the menu bar tooltip `notify` leaves behind.
    ///
    /// `notify` exists so a failed paste does not throw a dialog in front of what somebody
    /// was typing. Here they have just dismissed a dialog of their own and are waiting on
    /// it, so there is nothing to interrupt, and a tooltip on an icon nobody is looking at is
    /// how the drop went unnoticed in the first place. The log line is kept either way.
    private func reportFlagFailure(_ problem: String) {
        notify("Phona", problem)
        let alert = NSAlert()
        alert.messageText = "The dictation was not flagged"
        alert.informativeText = problem
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The window that replaced the history file and the README.
    ///
    /// Built by hand because nothing in this app has a `Scene`, so there is no
    /// `WindowGroup` and no `openWindow` to reach for. The
    /// window is kept rather than released so a second open restores the pane and the
    /// selection the reader left behind.
    ///
    /// `NSApp.activate(ignoringOtherApps:)` is not optional here. When `show_in_dock` is off
    /// the app runs `.accessory`, and an accessory app that orders a window front without
    /// activating leaves it behind whatever was in front, with no menu bar of its own.
    private static let mainWindowAutosaveName = "PhonaMainWindow"

    @objc private func openMainWindow() {
        if let window = mainWindow {
            historyStore.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Phona"
        /// The sidebar's own minimum plus the detail floor, kept in step with
        /// `MainWindowView` rather than guessed. A window minimum larger than the view
        /// needs is indistinguishable from a window that cannot be resized, which is how
        /// the old 900x620 pair was reported.
        window.contentMinSize = NSSize(width: 700, height: 340)
        let hosting = NSHostingView(
            rootView: MainWindowView(store: historyStore,
                                     model: windowModel,
                                     flag: { [weak self] in self?.flagLastDictation() }))
        /// The window's size is the window's business.
        ///
        /// `NSHostingView` reports the SwiftUI content's intrinsic size by default and
        /// AppKit sizes the window to it, which is how this window once opened 1541pt tall
        /// on a 1290pt screen and autosaved itself off the bottom of the display. Clearing
        /// `sizingOptions` is the supported way to say the content fits the window rather
        /// than the other way round, and it is what lets the reader drag it to any size the
        /// platform expects a window to reach.
        hosting.sizingOptions = []
        window.contentView = hosting
        /// `NSHostingView` reports the SwiftUI content's intrinsic size and AppKit sizes the
        /// window to it, which silently overrode the 980x660 above. The home pane's chart and
        /// sections add up to about 1541pt, so the window opened 1541pt tall on a 1290pt
        /// screen and autosaved itself off-screen at y=-251, which is both "it takes the whole
        /// vertical space" and "nothing appears when I open it".
        ///
        /// Every pane scrolls, so the window is entitled to pick its own size and let the
        /// content fit inside it rather than the other way round.
        window.setContentSize(NSSize(width: 980, height: 660))

        /// Remember whatever size it is dragged to, and restore it.
        ///
        /// Called once, and only here, after `setContentSize`. An earlier version also
        /// called it before the hosting view was installed, which restored the saved frame
        /// first and let an oversized one survive the resize below it.
        ///
        /// `setFrameUsingName` reports whether anything was restored, so the centring is
        /// conditional without hand-building AppKit's `NSWindow Frame <name>` defaults key,
        /// which is private to the framework and not ours to depend on. Centring
        /// unconditionally is what threw the remembered position away before.
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        if !window.setFrameUsingName(Self.mainWindowAutosaveName) { window.center() }

        /// A remembered frame can outlive the display it was saved on, and one saved before
        /// the line above existed can be larger than any screen. Clamp on the way in so a bad
        /// value corrects itself instead of persisting.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        /// Logged because the window's own size is what went wrong here and it is not
        /// otherwise visible after the fact: it opened 1541pt tall on a 1290pt screen and
        /// autosaved itself off-screen, which reads as the window never appearing.
        Paths.log("main window opened at \(Int(window.frame.width))x\(Int(window.frame.height))")
        mainWindow = window
        historyStore.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A main menu, without which no window in this app can copy or paste.
    ///
    /// `grep -rn mainMenu` returned nothing before this release: the app never set one. Cmd-C,
    /// Cmd-V, Cmd-X, Cmd-A and Cmd-Z are not built into a text view, they are menu items whose
    /// key equivalents the menu bar dispatches, so with no main menu every one of them does
    /// nothing at all. The Settings sheet survived that because it is a form people type into.
    /// A History pane whose whole purpose is copying text out cannot.
    ///
    /// Every editing item is sent to the first responder with a nil target rather than to this
    /// delegate. That is what lets whichever text view is focused claim the ones it can handle
    /// and lets the rest grey themselves out, which a target on the delegate would defeat.
    ///
    /// Under `.accessory` the app owns no menu bar until it activates, so these items are only
    /// on screen while one of Phona's own windows is in front. Cmd-0 therefore reaches the
    /// window from inside the app, and from anywhere else the status menu is the way in.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Phona")
        appMenu.addItem(withTitle: "About Phona",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings\u{2026}",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Phona",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Phona",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        /// A View menu, because the window's toolbar is not allowed to be the only route to
        /// a command. A toolbar can be hidden, and on this platform the expectation is a
        /// keyboard route to every view a window can show, so the four record panes get
        /// Command-1 through Command-4 and the five history filters get named items.
        ///
        /// Settings is left out on purpose, even though it is a pane like the others. Its
        /// item belongs in the App menu, which already has it on Command-comma, and listing
        /// it twice would put the same key equivalent on two menu items.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for pane in Pane.allCases where pane != .settings {
            let item = NSMenuItem(title: pane.title,
                                  action: #selector(showPane(_:)),
                                  keyEquivalent: String(pane.shortcut))
            item.target = self
            item.representedObject = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        let filterItem = NSMenuItem(title: "Filter History", action: nil, keyEquivalent: "")
        let filterMenu = NSMenu(title: "Filter History")
        for filter in HistoryFilter.allCases {
            let item = NSMenuItem(title: filter.title,
                                  action: #selector(showFilter(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = filter.rawValue
            item.image = NSImage(systemSymbolName: filter.symbol, accessibilityDescription: nil)
            filterMenu.addItem(item)
        }
        filterItem.submenu = filterMenu
        viewMenu.addItem(filterItem)
        viewMenu.addItem(.separator())
        /// A string selector, because `toggleSidebar:` is declared by AppKit's split view
        /// controller rather than by anything this file can see, and it is sent to the
        /// first responder with no target so whichever window is in front handles it.
        ///
        /// Control-Command-S, which is what every other Mac app uses for this. Command-S on
        /// its own means save, and binding it here would train the wrong reflex in a window
        /// that has nothing to save.
        let sidebar = NSMenuItem(title: "Toggle Sidebar",
                                 action: NSSelectorFromString("toggleSidebar:"),
                                 keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(sidebar)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let home = NSMenuItem(title: "Phona Home",
                              action: #selector(openMainWindow), keyEquivalent: "0")
        home.target = self
        windowMenu.addItem(home)
        windowMenu.addItem(.separator())
        /// Here rather than under a File menu, where the standard AppKit menu puts it,
        /// because this app has no files and closing is a window operation. The key
        /// equivalent is the point: every window it opens is `.closable`, so the red button
        /// worked while Cmd-W did nothing, which reads as a stuck window, not a thin menu.
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        /// A Help menu, at the trailing end where the platform puts one. There was none at
        /// all, which is the one menu a Mac app is expected to have and the first place
        /// anyone looks when they do not understand what they are seeing.
        ///
        /// The route legend is here as well as behind the window's toolbar button, because
        /// it is the only explanation of the app's privacy claim and it should not need a
        /// window open to reach.
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let help = NSMenuItem(title: "Phona Help",
                              action: #selector(openHelp), keyEquivalent: "?")
        help.target = self
        helpMenu.addItem(help)
        let dots = NSMenuItem(title: "What the Marks on a Dictation Mean",
                              action: #selector(explainRoutes), keyEquivalent: "")
        dots.target = self
        helpMenu.addItem(dots)
        helpMenu.addItem(.separator())
        let releases = NSMenuItem(title: "Release Notes",
                                  action: #selector(openReleases), keyEquivalent: "")
        releases.target = self
        helpMenu.addItem(releases)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    /// Move the window to a pane, opening it first when it is closed.
    ///
    /// Command-1 with no window is a request to see that pane, not a request to do nothing,
    /// so the window opens rather than the keystroke being swallowed.
    @objc private func showPane(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pane = Pane(rawValue: raw) else { return }
        windowModel.pane = pane
        openMainWindow()
    }

    @objc private func showFilter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let filter = HistoryFilter(rawValue: raw) else { return }
        windowModel.filter = filter
        windowModel.pane = .history
        openMainWindow()
    }

    /// The README, which is this app's documentation.
    ///
    /// Not a Help Book. Phona ships as a directory, not an installer, and its whole manual
    /// is one README that is already kept current because it is the project's front page. A
    /// bundled Help Book would be a second copy of it, out of date within a release.
    @objc private func openHelp() {
        guard let url = URL(string: "https://github.com/basal-john/phona#readme") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The route legend, from the menu bar, with no window needed.
    @objc private func explainRoutes() {
        openMainWindow()
        windowModel.legendShown = true
    }

    @objc private func openReleases() { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
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

    /// A dictation failed outright. Say so, and keep saying so.
    ///
    /// The capsule leaves after a couple of seconds whatever happens, and a warning triangle
    /// that brief is easy to read as an ordinary empty dictation. That is how a dozen
    /// consecutive ffmpeg failures went unnoticed. The menu bar keeps a mark until a
    /// dictation succeeds, so a persistent breakage looks persistent.
    ///
    /// The image position has to move with the title. A button showing only an image sits at
    /// `.imageOnly`, and assigning a title flips it to `.imageOverlaps` without widening the
    /// item, which draws the mark on top of the Φ instead of beside it.
    private func fail(_ reason: String) {
        notify("Phona", reason)
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.title = " !"
        Cue.nothing.play()
        hud.finish(.failed)
    }

    /// Clear the mark, and only the mark.
    ///
    /// The tooltip is left alone. A successful paste can set it moments earlier to say the
    /// clipboard held an image that could not be restored, and clearing it here destroyed
    /// the only notice of that before it could be read.
    private func clearFailureMark() {
        guard statusItem?.button?.title.isEmpty == false else { return }
        statusItem?.button?.title = ""
        statusItem?.button?.imagePosition = .imageOnly
    }

    /// Drop takes left behind by dictations that never completed.
    ///
    /// A finished take is deleted once the daemon has answered, but a crash, a failure or a
    /// dead microphone leaves the wav on disk for good. An hour of a wedged capture layer
    /// left a pile of 4 kB files that nothing was ever going to collect.
    ///
    /// It runs on a timer as well as at launch. Phona is a menu bar app that stays resident
    /// for days, so a launch-only sweep never collects anything the running session leaks.
    ///
    /// An unreadable modification date is a reason to keep a file, not to delete it. The CLI
    /// writes its own takes into the same directory, so a sweeper that cannot date a file
    /// must leave it where it is.
    private func sweepAbandonedTakes() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in entries where url.lastPathComponent.hasPrefix("take-")
            && url.pathExtension == "wav" {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            guard modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
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
        if let version = UpdateCheck.availableVersion {
            let item = NSMenuItem(title: "Update to \(version) is available",
                                  action: #selector(openReleases), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        add(menu, "Phona Home...", #selector(openMainWindow), key: "0")
        add(menu, "Settings\u{2026}", #selector(openSettings), key: ",")
        add(menu, "Setup and permissions...", #selector(showOnboarding))
        add(menu, "Mark last dictation as wrong...", #selector(flagLastDictation))
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

extension AppDelegate: NSWindowDelegate {
    /// Re-read the history when the window comes forward, and only then.
    ///
    /// A timer would re-read a growing file on a schedule nobody asked for, and the only
    /// moment a stale figure matters is the moment somebody looks at it. The notification
    /// arrives for every window that becomes key, so it is filtered to this one.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        historyStore.reload()
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

/// Photograph the windows, on a fixture history, and exit.
///
/// A sibling of `--render` for everything `ImageRenderer` cannot draw, which on macOS is
/// every window this app has. It needs a real `NSApplication` with a regular activation
/// policy, because a window belonging to a prohibited or accessory app never reaches the
/// compositor and `screencapture` photographs nothing.
if let idx = CommandLine.arguments.firstIndex(of: "--shots") {
    let dir = CommandLine.arguments.count > idx + 1
        ? URL(fileURLWithPath: CommandLine.arguments[idx + 1])
        : URL(fileURLWithPath: "/tmp/phona-shots")
    let shotApp = NSApplication.shared
    shotApp.setActivationPolicy(.regular)
    MainActor.assumeIsolated { Previews.shoot(into: dir) }
    exit(0)
}

/// Check the render fixture, and exit.
///
/// The fixture is what every screenshot in this repo is drawn from, so a fault in it reads
/// as a fault in the window. This is here because it caught one: the fixture was built
/// newest-first, `HistoryOrder.newestFirst` reverses file position rather than sorting, and
/// the History pane came out with its oldest day at the top. The fixture lives in the
/// executable target, which no test target can import, so the check runs here.
if CommandLine.arguments.contains("--check-fixtures") {
    let snapshot = Fixtures.snapshot()
    let descending = HistoryOrder.newestFirst(snapshot.rows)
    var failures: [String] = []

    let stamps = descending.map(\.ts)
    if let firstOutOfOrder = zip(stamps, stamps.dropFirst()).first(where: { $0 < $1 }) {
        failures.append("descending is not newest first: \(firstOutOfOrder.0) precedes \(firstOutOfOrder.1)")
    }
    if snapshot.rows.count < 40 {
        failures.append("only \(snapshot.rows.count) rows, too few to fill a list")
    }
    if snapshot.flaggedRowCount != 1 {
        failures.append("expected exactly one flagged row, got \(snapshot.flaggedRowCount)")
    }
    if !snapshot.rows.contains(where: \.guarded) { failures.append("no guarded row") }
    if !snapshot.rows.contains(where: \.trimmed) { failures.append("no trimmed row") }
    if !snapshot.rows.contains(where: { $0.route == .cloud }) { failures.append("no cloud row") }
    if !snapshot.rows.contains(where: { !$0.isSpoken }) { failures.append("no typed row") }
    if !snapshot.rows.contains(where: { $0.sttSecs + $0.llmSecs > Insights.slowSeconds }) {
        failures.append("no slow row")
    }

    if failures.isEmpty {
        print("fixture ok: \(snapshot.rows.count) rows, "
            + "newest \(descending.first.map { "\($0.ts)" } ?? "none"), "
            + "oldest \(descending.last.map { "\($0.ts)" } ?? "none")")
        exit(0)
    }
    for failure in failures { print("fixture FAIL: \(failure)") }
    exit(1)
}

/// Print which models the app believes are loaded, and where each answer came from.
///
/// A sibling of `--probe-focus` and `--probe-style`. It exists because the Models pane
/// spent a release reporting that no cloud model was configured while cloud corrections
/// were being made: it read config.json, which does not carry `cloud_model` on a default
/// install, and never asked the daemon, which merges the file over its own defaults. This
/// prints both sides so the two can be compared without opening the window.
if CommandLine.arguments.contains("--probe-models") {
    let running = DaemonClient.models()
    var config: [String: Any] = [:]
    if let data = try? Data(contentsOf: Paths.config),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        config = obj
    }
    func line(_ label: String, _ key: String, _ fromDaemon: String?) {
        let pinned = (config[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let used = fromDaemon ?? pinned
        let padded = label.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("\(padded) used=\(used ?? "none")  daemon=\(fromDaemon ?? "none")  "
            + "config=\(pinned ?? "none")")
    }
    /// `models()` returns nil for two different reasons and they are worth telling apart:
    /// no daemon at all, or a daemon that did not answer STATUS, which is what an older
    /// one does. PING is the older command, so it separates them.
    if running != nil {
        print("daemon: reachable, and answered STATUS")
    } else if DaemonClient.isAlive() {
        print("daemon: reachable but did not answer STATUS, so every answer below falls "
            + "back to config.json")
    } else {
        print("daemon: not reachable, so every answer below falls back to config.json")
    }
    line("speech", "stt_model", running?.sttModel)
    line("local", "llm_model", running?.llmModel)
    line("cloud", "cloud_model", running?.cloudModel)
    line("backend", "cloud_backend", running?.cloudBackend)
    exit(0)
}

if CommandLine.arguments.contains("--check-mute") {
    OutputMute.report()
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
