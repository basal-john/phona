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
                              ("hud-done", .done),
                              ("hud-clipboard", .clipboard),
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

        render(documentShot(SettingsView().frame(width: 460, height: 620)),
               to: directory.appendingPathComponent("settings.png"))
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
