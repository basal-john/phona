import AppKit
import SwiftUI

enum HUDState: Equatable {
    case hidden
    case listening
    case working
    case done
    case failed
}

/// Shared state the HUD view observes.
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
    @Published var level: Double = 0
}

/// The capsule. Real vibrancy underneath, so it picks up whatever is behind it rather
/// than faking depth with a flat dark fill.
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

    // Apple parameterises springs as response plus bounce. Critically damped for the
    // surface itself, a little looser for the bars since they track something physical.
    private var surfaceSpring: Animation { .spring(duration: 0.34, bounce: 0) }
    private var barSpring: Animation { .spring(duration: 0.16, bounce: 0.28) }

    private var shown: Bool { model.state != .hidden }

    /// Height profile across the bars. The centre leads so it reads as a voice.
    private func barHeight(_ index: Int) -> CGFloat {
        switch model.state {
        case .listening:
            let profile: [Double] = [0.55, 0.82, 1.0, 0.82, 0.55]
            let scaled = model.level * profile[index]
            return barMin + (barMax - barMin) * CGFloat(scaled)
        case .working:
            return barMin + 3
        case .done, .failed, .hidden:
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
            .opacity(model.state == .done || model.state == .failed ? 0 : 1)

            Image(systemName: model.state == .failed ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(model.state == .failed ? Color.orange : Color.green)
                .opacity(model.state == .done || model.state == .failed ? 1 : 0)
                .scaleEffect(model.state == .done || model.state == .failed ? 1 : 0.6)
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
        // Lift, scale and opacity all derive from one condition, so the capsule arrives
        // as a single object instead of three properties landing at different times.
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

/// A non-activating panel, so showing the HUD never steals focus from what you are typing into.
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
        // Always dark, like the system dictation and volume overlays, so the white
        // waveform stays legible whatever appearance the user runs.
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

    func finish(success: Bool) {
        guard model.state != .hidden else { return }
        dismissWork?.cancel()
        model.state = success ? .done : .failed
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 0.45 : 0.8), execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        model.state = .hidden
        // Leave the window up until the exit spring has played out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.model.state == .hidden else { return }
            self.orderOut(nil)
        }
    }
}
