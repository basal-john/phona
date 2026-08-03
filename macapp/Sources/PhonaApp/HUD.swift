import AppKit
import SwiftUI

enum HUDState: Equatable {
    case hidden
    case listening
    case working
    case done
    /// Nothing usable was heard. Distinct from `failed` because it is not an error, so it
    /// gets no warning glyph and leaves without complaint.
    case cancelled
    /// Transcribed, but there was nowhere to put it, so it waits on the clipboard.
    case clipboard
    case failed
}

/// Shared state the HUD view observes.
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
    @Published var level: Double = 0
}

/// The capsule. Real vibrancy underneath, so it picks up whatever is behind it rather
/// than faking depth with a flat dark fill.
///
/// Lift, scale and opacity all derive from one condition, so it arrives as a single object
/// instead of three properties landing at slightly different times.
struct HUDView: View {
    @ObservedObject var model: HUDModel
    /// ImageRenderer cannot draw an NSViewRepresentable, so previews swap the
    /// vibrancy layer for a solid fill of comparable weight.
    var solidBackground = false

    private let barCount = 5
    private let barWidth: CGFloat = 4
    private let barGap: CGFloat = 7
    private let barMin: CGFloat = 4
    private let barMax: CGFloat = 22

    /// Apple parameterises springs as response plus bounce rather than mass, stiffness and
    /// damping. Critically damped, because overshoot on something that merely appeared reads
    /// as noise.
    private var surfaceSpring: Animation { .spring(duration: 0.34, bounce: 0) }
    /// Looser than the surface, since the bars track something physical.
    private var barSpring: Animation { .spring(duration: 0.16, bounce: 0.28) }

    private var shown: Bool { model.state != .hidden }

    private var showsGlyph: Bool {
        model.state == .done || model.state == .failed || model.state == .clipboard
    }

    /// The clipboard case gets its own glyph, because a checkmark would claim the text
    /// was placed when it was not.
    private var glyphName: String {
        switch model.state {
        case .failed: return "exclamationmark.triangle.fill"
        case .clipboard: return "doc.on.clipboard"
        default: return "checkmark"
        }
    }

    private var glyphColour: Color {
        switch model.state {
        case .failed: return .orange
        case .clipboard: return .yellow
        default: return .green
        }
    }

    /// Height profile across the bars. The centre leads so it reads as a voice.
    private func barHeight(_ index: Int) -> CGFloat {
        switch model.state {
        case .listening:
            let profile: [Double] = [0.55, 0.82, 1.0, 0.82, 0.55]
            let scaled = model.level * profile[index]
            return barMin + (barMax - barMin) * CGFloat(scaled)
        case .working:
            return barMin + 3
        case .done, .failed, .cancelled, .clipboard, .hidden:
            return 0
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: barGap) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: barWidth, height: barHeight(i))
                        .animation(barSpring, value: model.level)
                        .animation(surfaceSpring, value: model.state)
                }
            }
            .opacity(showsGlyph ? 0 : 1)

            Image(systemName: glyphName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(glyphColour)
                .opacity(showsGlyph ? 1 : 0)
                .scaleEffect(showsGlyph ? 1 : 0.6)
                .animation(surfaceSpring, value: model.state)
        }
        .frame(width: 124, height: 40)
        .background(
            Group {
                if solidBackground {
                    Capsule().fill(Color(white: 0.13).opacity(0.92))
                } else {
                    VisualEffect(material: .hudWindow, blending: .behindWindow)
                        .clipShape(Capsule())
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .scaleEffect(shown ? 1 : 0.94)
        .offset(y: shown ? 0 : 14)
        .opacity(shown ? 1 : 0)
        .animation(surfaceSpring, value: shown)
        .frame(width: 260, height: 120)
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
    /// at once because there is nothing to read, a failure stays long enough for the warning
    /// to register, and the clipboard case stays longest since it is the only one asking the
    /// user to do something.
    func finish(_ outcome: HUDState) {
        guard model.state != .hidden else { return }
        dismissWork?.cancel()
        model.state = outcome
        let linger: TimeInterval
        switch outcome {
        case .done: linger = 0.45
        case .cancelled: linger = 0.3
        case .clipboard: linger = 1.4
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
