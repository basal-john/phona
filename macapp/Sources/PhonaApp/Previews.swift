import AppKit
import SwiftUI

/// Offscreen rendering of every screen the app can show.
///
/// Run `phona --render <dir>` to write a PNG per view and state. This makes the interface
/// reviewable without a live display, and gives a cheap visual regression check: rebuild,
/// re-render, compare.
enum Previews {
    /// Write every state to a PNG.
    ///
    /// The HUD normally sits on a vibrancy layer, which has nothing to sample offscreen, so
    /// it is rendered on a representative backdrop to keep the contrast honest.
    @MainActor
    static func renderAll(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, state) in [("hud-listening", HUDState.listening),
                              ("hud-working", .working),
                              ("hud-working-cloud", .workingInCloud),
                              ("hud-done", .done),
                              ("hud-clipboard", .clipboard),
                              ("hud-trimmed", .trimmed),
                              ("hud-failed", .failed)] {
            let model = HUDModel()
            model.state = state
            model.level = state == .listening ? 0.72 : 0
            render(ZStack {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.26)],
                               startPoint: .top, endPoint: .bottom)
                HUDView(model: model, solidBackground: true)
            }.frame(width: 260, height: 120),
            to: directory.appendingPathComponent("\(name).png"))
        }

        let fresh = PermissionState()
        fresh.accessibility = false
        fresh.microphone = false
        fresh.engine = false
        render(documentShot(OnboardingView(state: fresh, onDone: {})),
               to: directory.appendingPathComponent("onboarding-fresh.png"))

        let ready = PermissionState()
        ready.accessibility = true
        ready.microphone = true
        ready.engine = true
        render(documentShot(OnboardingView(state: ready, onDone: {})),
               to: directory.appendingPathComponent("onboarding-ready.png"))
    }

    /// Screenshots of the real windows, on a fixture history.
    ///
    /// `ImageRenderer` is not usable for these. It cannot draw an `NSViewRepresentable`, and
    /// on macOS the pieces this app is built from are all AppKit views underneath:
    /// `NavigationSplitView`, `List`, `ScrollView`, `TabView` and `Form`. A rendered pane
    /// comes out either blank or as the system's "cannot draw this" placeholder. The only
    /// honest picture of the window is the window.
    ///
    /// So the windows are opened for real, `screencapture` is pointed at each one by window
    /// number, and the app exits. The store is the fixture rather than the live history,
    /// because a screenshot of this window otherwise carries whatever its owner last
    /// dictated.
    @MainActor
    static func shoot(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let store = HistoryStore(previewing: Fixtures.snapshot())
        let empty = HistoryStore(previewing: HistorySnapshot.empty(now: Fixtures.now))

        for (name, appearance) in [("window", NSAppearance.Name.aqua),
                                   ("window-dark", .darkAqua)] {
            shot(name: name,
                 appearance: appearance,
                 size: NSSize(width: 1000, height: 680),
                 into: directory,
                 view: MainWindowView(store: store, flag: {}))
        }

        /// The other three panes. History carries the most change of any of them, because
        /// its search moved into the toolbar and its two columns became a split view, and
        /// neither of those is visible on Home.
        for (name, pane) in [("window-history", Pane.history),
                             ("window-models", .models),
                             ("window-dictionary", .dictionary),
                             ("window-settings", .settings)] {
            let model = WindowModel()
            model.pane = pane
            shot(name: name,
                 appearance: .aqua,
                 size: NSSize(width: 1000, height: 680),
                 into: directory,
                 view: MainWindowView(store: store, model: model, flag: {}))
        }

        shot(name: "window-empty",
             appearance: .aqua,
             size: NSSize(width: 1000, height: 680),
             into: directory,
             view: MainWindowView(store: empty, flag: {}))



        /// The capsule on a busy backdrop, which is the only way to see what the material
        /// is doing. Over a flat fill, glass and a plain blur look the same.
        for (name, state) in [("hud-listening", HUDState.listening),
                              ("hud-cloud", .workingInCloud),
                              ("hud-done", .done)] {
            let model = HUDModel()
            model.state = state
            model.capturing = true
            model.level = state == .listening ? 0.72 : 0
            shot(name: name,
                 appearance: .darkAqua,
                 size: NSSize(width: 300, height: 150),
                 into: directory,
                 view: ZStack {
                     LinearGradient(colors: [.indigo, .teal, .orange],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                     HUDView(model: model)
                 })
        }

        shootPanel(into: directory)

        let permissions = PermissionState()
        permissions.accessibility = true
        permissions.microphone = false
        permissions.engine = false
        shot(name: "onboarding",
             appearance: .aqua,
             size: nil,
             into: directory,
             view: OnboardingView(state: permissions, onDone: {}))
    }

    /// Open one window, photograph it, close it.
    ///
    /// A real screenshot needs the window on screen and drawn, so each one is ordered front
    /// and the run loop is spun until the compositor has it. `screencapture -l` names the
    /// window by number, which keeps whatever else is on the desktop out of the frame.
    @MainActor
    private static func shot(name: String,
                             appearance: NSAppearance.Name,
                             size: NSSize?,
                             into directory: URL,
                             view: some View) {
        let window = NSWindow(contentRect: NSRect(origin: .zero,
                                                  size: size ?? NSSize(width: 540, height: 400)),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Phona"
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        /// A size given here is the window's, so the content fits inside it. No size means
        /// the content's, which is how the settings and setup windows actually open.
        if size != nil { hosting.sizingOptions = [] }
        window.contentView = hosting
        window.setContentSize(size ?? hosting.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Two passes: one to lay out, one to let the material and shadow settle.
        for _ in 0..<2 {
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline,
                  let event = NSApp.nextEvent(matching: .any, until: deadline,
                                              inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            window.displayIfNeeded()
        }

        let url = directory.appendingPathComponent("\(name).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-l\(window.windowNumber)", url.path]
        do {
            try capture.run()
            capture.waitUntilExit()
            print(capture.terminationStatus == 0
                ? "shot \(name).png"
                : "screencapture failed for \(name) (status \(capture.terminationStatus))")
        } catch {
            print("could not run screencapture: \(error.localizedDescription)")
        }
        window.orderOut(nil)
    }

    /// The real HUD panel, over a bright window, captured as a screen region.
    ///
    /// This one is not decoration. `NSVisualEffectView` with `behindWindow` blending samples
    /// what is behind the window, across app boundaries, which is the whole reason the HUD
    /// has ever looked like it is sitting on top of your work. A SwiftUI glass effect samples
    /// its own window's backdrop, and the HUD's window is a borderless panel with a clear
    /// background, so whether glass still picks up the app underneath is a question about the
    /// panel and cannot be answered by photographing the view inside an opaque test window.
    ///
    /// So the capture is by screen region rather than by window number: `screencapture -l`
    /// returns a window's own contents without whatever it was compositing against, which is
    /// exactly the part in question.
    @MainActor
    private static func shootPanel(into directory: URL) {
        guard let screen = NSScreen.main else { return }

        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.contentView = NSHostingView(rootView:
            LinearGradient(colors: [.indigo, .cyan, .yellow, .red],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        backdrop.level = .normal
        let visible = screen.visibleFrame
        backdrop.setFrameOrigin(NSPoint(x: visible.midX - 450, y: visible.minY + 40))
        backdrop.orderFrontRegardless()

        let panel = HUDPanel()
        panel.show(.listening)
        panel.model.capturing = true
        panel.model.level = 0.8
        settle()

        // screencapture takes a top-left origin rect, and NSWindow frames are bottom-left.
        let frame = panel.frame
        let top = screen.frame.maxY - frame.maxY
        let region = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
        let url = directory.appendingPathComponent("hud-panel-over-app.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-R", region, url.path]
        try? capture.run()
        capture.waitUntilExit()
        print(capture.terminationStatus == 0
            ? "shot hud-panel-over-app.png"
            : "screencapture failed for the panel (status \(capture.terminationStatus))")

        panel.orderOut(nil)
        backdrop.orderOut(nil)
    }

    /// Let the compositor catch up.
    @MainActor
    private static func settle() {
        for _ in 0..<2 {
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline,
                  let event = NSApp.nextEvent(matching: .any, until: deadline,
                                              inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// Wrap a view so the exported PNG is opaque.
    ///
    /// ImageRenderer leaves the background transparent, which looks fine locally because
    /// most viewers composite onto white. Embedded in a README it is not fine: GitHub's
    /// dark theme shows through the alpha and the dark text becomes unreadable. Painting
    /// an explicit light surface, with a hairline edge so it still has definition against
    /// a white page, makes one image legible in both themes.
    @MainActor
    private static func documentShot(_ view: some View) -> some View {
        view
            .background(Color(white: 0.97))
            .overlay(
                Rectangle().strokeBorder(Color(white: 0.80), lineWidth: 1)
            )
            .environment(\.colorScheme, .light)
    }

    @MainActor
    private static func render(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("could not render \(url.lastPathComponent)\n".data(using: .utf8)!)
            return
        }
        try? png.write(to: url)
        print("rendered \(url.lastPathComponent)")
    }
}
