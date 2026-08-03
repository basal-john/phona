import AppKit
import AVFoundation
import SwiftUI

/// First-run setup.
///
/// macOS will not let an app grant itself Accessibility or Microphone access, so the two
/// clicks are unavoidable. What is avoidable is making the user guess. Each row states
/// plainly why the permission is needed, opens the exact settings pane, and turns green
/// on its own the moment the grant lands, so there is no "did that work?" moment.
final class PermissionState: ObservableObject {
    @Published var accessibility = false
    @Published var microphone = false
    @Published var engine = false

    private var timer: Timer?

    var allGranted: Bool { accessibility && microphone }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        accessibility = HotkeyMonitor.hasAccessibility(prompt: false)
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        DispatchQueue.global().async {
            let alive = DaemonClient.isAlive()
            DispatchQueue.main.async { self.engine = alive }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var state: PermissionState
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Phona").font(.title2).fontWeight(.semibold)
                    Text("Hold Option, speak, let go. Your words arrive corrected, where the cursor is.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 22)

            PermissionRow(
                granted: state.accessibility,
                title: "Accessibility",
                detail: "Lets Phona notice the Option key and type into the app you are using.",
                action: "Open Settings",
                perform: {
                    _ = HotkeyMonitor.hasAccessibility(prompt: true)
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                })

            PermissionRow(
                granted: state.microphone,
                title: "Microphone",
                detail: "Records your voice. Transcription runs on this Mac, nothing is uploaded.",
                action: "Allow",
                perform: {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { state.refresh() }
                    }
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                })

            PermissionRow(
                granted: state.engine,
                title: "Speech engine",
                detail: state.engine
                    ? "Running. Whisper and the grammar model are warm."
                    : "Loading the models. The first start takes about a minute.",
                action: "Start",
                perform: { DispatchQueue.global().async { DaemonClient.startAndWait() } })

            Divider().padding(.vertical, 16)

            HStack {
                Text(state.allGranted
                     ? "You are set. Hold Option anywhere and start talking."
                     : "Phona stays in the menu bar. This window closes when you are done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(state.allGranted ? "Start using Phona" : "Later") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

private struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 22)
                // The tick is the confirmation, so it should feel like it landed.
                .animation(.spring(duration: 0.34, bounce: 0.2), value: granted)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if granted {
                Text("Granted").font(.callout).foregroundStyle(.secondary)
            } else {
                Button(action, action: perform)
            }
        }
        .padding(.vertical, 9)
    }
}
