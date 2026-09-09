import AppKit
import SwiftUI

enum HUDState: Equatable {
    case hidden
    case listening
    case working
    case workingInCloud
    case done
    /// Nothing usable was heard. Distinct from `failed` because it is not an error, so it
    /// gets no warning glyph and leaves without complaint.
    case cancelled
    /// Transcribed, but there was nowhere to put it, so it waits on the clipboard.
    case clipboard
    /// Delivered, but the transcriber looped and a repeated tail was cut off the end.
    ///
    /// Its own case rather than `done`, because the text that landed reads as a finished
    /// sentence while being shorter than what was said. Passing that off as a clean result
    /// is the one way trimming is worse than refusing outright.
    case trimmed
    case failed
}

/// Shared state the HUD view observes.
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
    @Published var level: Double = 0
    /// False until the input device has delivered its first buffer.
    ///
    /// The capsule is on screen about 180 ms after the key goes down. The first buffer was
    /// measured 568 ms after the hold armed, so around 700 ms after the keypress, on a device
    /// idle for under a minute. For that whole stretch the HUD is up and listening to nothing.
    /// Showing a moving waveform through it invited speech the microphone could not hear yet,
    /// and the first word went missing. The bars now sit dim and still until there is genuinely
    /// something to draw.
    @Published var capturing = false
}

/// The capsule.
///
/// This is the one element in Phona that earns a custom material. It floats over whatever
/// app the speaker is typing into, it is the only thing on screen during a dictation, and it
/// is the app's single most-seen surface, which is exactly the "most important functional
/// element" the platform reserves glass for. Everything else in the app uses standard
/// components and inherits their appearance instead.
///
/// So the capsule is Liquid Glass where the OS has it, and a vibrancy layer underneath that,
/// and a flat fill under Reduce Transparency. Regular glass rather than clear: it sits over
/// arbitrary app windows rather than over media, and the guidance is that regular is the
/// variant for a component whose background might create legibility problems.
///
/// Lift, scale and opacity all derive from one condition, so it arrives as a single object
/// instead of three properties landing at slightly different times.
struct HUDView: View {
    @ObservedObject var model: HUDModel
    /// ImageRenderer cannot draw an NSViewRepresentable, so previews swap the
    /// vibrancy layer for a solid fill of comparable weight.
    var solidBackground = false

    /// Both of these change what the capsule is allowed to do, and both are the reader's
    /// choice rather than this app's. Reduce Transparency replaces the material with a
    /// solid surface, and Reduce Motion removes the spring, the lift and the scale, so the
    /// capsule cuts in and out instead of moving.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 5
    private let cloudBarCount = 3
    private let barWidth: CGFloat = 4
    private let barGap: CGFloat = 7
    private let cloudBarGap: CGFloat = 6
    private let barMin: CGFloat = 4
    private let barMax: CGFloat = 22

    /// Apple parameterises springs as response plus bounce rather than mass, stiffness and
    /// damping. Critically damped, because overshoot on something that merely appeared reads
    /// as noise.
    ///
    /// Under Reduce Motion the spring is gone entirely rather than shortened. The setting is
    /// a request for no automatic motion, not for faster motion.
    private var surfaceSpring: Animation? {
        reduceMotion ? nil : .spring(duration: 0.34, bounce: 0)
    }
    /// Presence is not motion, so it does not get the spring.
    ///
    /// A `spring(duration: 0.34)` settles in 0.500 s, not 0.34, and reaches only half opacity
    /// at 118 ms and 90 percent at 235 ms. Fading the capsule in on it was the difference
    /// between a HUD that has arrived and one that is still arriving. The lift and the scale
    /// keep the spring, because those are motion and reading as physical is the point.
    ///
    /// A cross-fade survives Reduce Motion. It is the substitution the setting asks for.
    private var presence: Animation { .easeOut(duration: 0.09) }
    /// Looser than the surface, since the bars track something physical.
    private var barSpring: Animation? {
        reduceMotion ? nil : .spring(duration: 0.16, bounce: 0.28)
    }

    private var shown: Bool { model.state != .hidden }

    private var isCloud: Bool { model.state == .workingInCloud }

    /// Listening, but the device has not produced a buffer yet.
    private var waitingForAudio: Bool { model.state == .listening && !model.capturing }

    private var showsGlyph: Bool {
        model.state == .done || model.state == .failed || model.state == .clipboard
            || model.state == .trimmed
    }

    /// The clipboard case gets its own glyph, because a checkmark would claim the text
    /// was placed when it was not. The trimmed case gets scissors for the same reason:
    /// text arrived, but not all of what was said.
    private var glyphName: String {
        switch model.state {
        case .failed: return "exclamationmark.triangle.fill"
        case .clipboard: return "doc.on.clipboard"
        case .trimmed: return "scissors"
        case .done, .hidden, .listening, .working, .workingInCloud, .cancelled:
            return "checkmark"
        }
    }

    private var glyphColour: Color {
        switch model.state {
        case .failed: return .orange
        case .clipboard: return .yellow
        case .trimmed: return .yellow
        case .workingInCloud: return .blue
        case .done, .hidden, .listening, .working, .cancelled:
            return .green
        }
    }

    /// Height profile across the bars. The centre leads so it reads as a voice.
    private func barHeight(_ index: Int) -> CGFloat {
        switch model.state {
        case .listening:
            let profile: [Double] = [0.55, 0.82, 1.0, 0.82, 0.55]
            let scaled = model.level * profile[index]
            return barMin + (barMax - barMin) * CGFloat(scaled)
        case .working, .workingInCloud:
            return barMin + 3
        case .done, .failed, .cancelled, .clipboard, .trimmed, .hidden:
            return 0
        }
    }

    private func barFill(_ index: Int) -> Color {
        if isCloud {
            let opacities: [Double] = [1.0, 0.55, 0.30]
            let opacity = index < opacities.count ? opacities[index] : 1.0
            return Color.blue.opacity(opacity)
        }
        return Color.white.opacity(waitingForAudio ? 0.30 : 0.92)
    }

    var body: some View {
        ZStack {
            HStack(spacing: isCloud ? cloudBarGap : barGap) {
                if isCloud {
                    Image(systemName: "cloud")
                        .font(.headline)
                        .foregroundStyle(Color.blue)
                }

                ForEach(Array(0..<(isCloud ? cloudBarCount : barCount)), id: \.self) { i in
                    Capsule()
                        .fill(barFill(i))
                        .frame(width: barWidth, height: barHeight(i))
                        .animation(barSpring, value: model.level)
                        .animation(surfaceSpring, value: model.state)
                        .animation(presence, value: waitingForAudio)
                }
            }
            .opacity(showsGlyph ? 0 : 1)

            Image(systemName: glyphName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(glyphColour)
                .opacity(showsGlyph ? 1 : 0)
                .scaleEffect(showsGlyph ? 1 : 0.6)
                .animation(surfaceSpring, value: model.state)
        }
        .frame(width: 124, height: 40)
        .background(surface)
        .compositingGroup()
        /// The material carries its own shadow on the OS that has it, so a second one drawn
        /// here would double it.
        .shadow(color: .black.opacity(glassAvailable ? 0 : 0.28), radius: 14, y: 6)
        .scaleEffect(shown || reduceMotion ? 1 : 0.94)
        .offset(y: shown || reduceMotion ? 0 : 14)
        .animation(surfaceSpring, value: shown)
        .opacity(shown ? 1 : 0)
        .animation(presence, value: shown)
        .frame(width: 260, height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Phona")
        .accessibilityValue(spokenState)
        .accessibilityHidden(!shown)
    }

    /// Whether this build is running where Liquid Glass exists.
    ///
    /// Phona still supports macOS 14, so the material cannot simply be used. Below 26 the
    /// capsule keeps the `hudWindow` vibrancy layer it has always had, which is the same
    /// material the system's own volume and dictation overlays use on those releases.
    private var glassAvailable: Bool {
        if #available(macOS 26, *) { return !reduceTransparency && !solidBackground }
        return false
    }

    /// The capsule's surface, in the strongest form this Mac and this reader allow.
    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26, *), glassAvailable {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(isCloud ? .blue.opacity(0.18) : .clear),
                             in: .capsule)
        } else if solidBackground || reduceTransparency {
            /// No material at all: an opaque surface, and a real border rather than a
            /// hairline of white at 14 percent, because Reduce Transparency is usually
            /// turned on alongside Increase Contrast.
            Capsule()
                .fill(Color(white: 0.13))
                .overlay(Capsule().strokeBorder(isCloud ? Color.blue : Color.white.opacity(0.55),
                                                lineWidth: 1))
        } else {
            VisualEffect(material: .hudWindow, blending: .behindWindow)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(
                    isCloud ? Color.blue.opacity(0.55) : Color.white.opacity(0.14),
                    lineWidth: 1))
        }
    }

    /// What the capsule would say if it could be read out.
    ///
    /// The panel is non-activating and ignores the mouse, so VoiceOver will not land on it
    /// on its own. The label is still worth having: it is what Accessibility Inspector and
    /// screen-recording tools report, and it is the description that becomes correct the
    /// moment the panel is ever made focusable.
    private var spokenState: String {
        switch model.state {
        case .hidden: return "idle"
        case .listening: return model.capturing ? "listening" : "starting to listen"
        case .working: return "correcting on this Mac"
        case .workingInCloud: return "correcting in the cloud"
        case .done: return "delivered"
        case .cancelled: return "nothing heard"
        case .clipboard: return "copied to the clipboard"
        case .trimmed: return "delivered, with a repeated ending cut off"
        case .failed: return "failed"
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// A non-activating panel, so showing the HUD never steals focus from what you are typing
/// into. Pinned to a dark appearance like the system dictation and volume overlays, so the
/// white waveform stays legible whatever appearance the user runs.
final class HUDPanel: NSPanel {
    let model = HUDModel()
    private var dismissWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: HUDView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show on whichever screen the user is actually working on.
    private func reposition() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: frame.midX - 130, y: frame.minY + 96))
    }

    func show(_ state: HUDState) {
        dismissWork?.cancel()
        reposition()
        orderFrontRegardless()
        model.state = state
    }

    /// Show the outcome, then leave.
    ///
    /// How long it lingers depends on what it is asking of the reader. A cancel goes almost
    /// at once because there is nothing to read, and the cases that ask the user to do
    /// something stay longest.
    ///
    /// A failure used to leave after 0.8 s, with the reason only in the menu bar tooltip.
    /// When ffmpeg went missing that read as an ordinary empty dictation, and the real
    /// breakage went unnoticed for over half an hour across a dozen attempts. A failure now
    /// outstays every other outcome, and the menu bar carries a mark until the next one
    /// succeeds.
    func finish(_ outcome: HUDState) {
        guard model.state != .hidden else { return }
        dismissWork?.cancel()
        model.state = outcome
        let linger: TimeInterval
        switch outcome {
        case .done: linger = 0.45
        case .cancelled: linger = 0.3
        case .clipboard: linger = 1.4
        case .trimmed: linger = 1.4
        case .failed: linger = 2.5
        default: linger = 0.8
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    /// Hide the capsule once the exit spring has played out, rather than cutting it off.
    func dismiss() {
        dismissWork?.cancel()
        model.state = .hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.model.state == .hidden else { return }
            self.orderOut(nil)
        }
    }
}
