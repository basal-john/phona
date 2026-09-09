import PhonaCore
import ServiceManagement
import SwiftUI

/// Real fields for the settings that previously meant hand-editing config.json.
struct SettingsView: View {
    @State private var dictionary: String = ""
    @State private var replacements: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var biasVocabulary: Bool = false
    @State private var outputAction: OutputAction = .insert
    @State private var spokenLayout: Bool = true
    @State private var casualInChat: Bool = true
    @State private var muteOthers: Bool = true
    @State private var showInDock: Bool = true
    @State private var status: String = ""
    /// Whether `status` is reporting a save or reporting a fault.
    ///
    /// One string carried both, and the notice headlined all of it "Saved", so a login-item
    /// failure appeared under the word Saved. They are different messages and the reader
    /// has to be able to tell which one they are looking at.
    @State private var statusIsFailure = false
    @State private var loaded: EngineSettings?

    /// Every setting, in one scrolling form.
    ///
    /// This was three tabs in a window of its own, opened from the App menu, which is where
    /// the platform puts settings. It is a pane of the main window instead because that is
    /// what its owner asked for: the sidebar already lists everything else the app can show
    /// and Settings was the one thing missing from it.
    ///
    /// One form rather than tabs inside a pane. A segmented switcher nested inside a
    /// sidebar selection is two levels of navigation for three groups of controls, and the
    /// whole form is shorter than one screen of History.
    ///
    /// Capped at 640pt and centred. A grouped form stretched across an 840pt detail pane
    /// puts its labels and its controls at opposite ends of the window, which is a long way
    /// for the eye to travel to check whether a toggle is on.
    var body: some View {
        Form {
            pendingRestart

            Section("Output") {
                Picker("When done", selection: $outputAction) {
                    Text("Insert at cursor").tag(OutputAction.insert)
                    Text("Copy to clipboard").tag(OutputAction.clipboard)
                    Text("Insert and copy").tag(OutputAction.both)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: outputAction) { _, wanted in
                    Settings.set("output_action", wanted.rawValue)
                }
                Text(outputExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Phona itself") {
                Toggle("Show Phona in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, wanted in
                        Settings.set("show_in_dock", wanted)
                        NSApp.setActivationPolicy(wanted ? .regular : .accessory)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                Toggle("Open Phona at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in
                        do {
                            if wanted { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            status = error.localizedDescription
                            statusIsFailure = true
                        }
                    }
            }

            Section("While dictating") {
                Toggle("Mute other audio", isOn: $muteOthers)
                    .onChange(of: muteOthers) { _, wanted in
                        Settings.set("mute_others", wanted)
                    }
                Text("Music, a video or a voice on a call reaches the microphone through the "
                     + "room, and the transcriber cannot tell it apart from you. The output "
                     + "device is muted once capture starts and restored when you let go.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Layout") {
                Toggle("Act on spoken layout commands", isOn: $spokenLayout)
                Text("Say \"new paragraph\", \"new line\" or \"bullet point\" as a sentence "
                     + "of its own and it becomes a real break. Off means those words are "
                     + "typed out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Chat apps") {
                Toggle("Drop the closing full stop", isOn: $casualInChat)
                    .onChange(of: casualInChat) { _, wanted in
                        Settings.set("casual_in_chat", wanted)
                    }
                Text("In Slack, Discord, WhatsApp, Teams, Messages and the same sites in a "
                     + "browser, a message ends without a full stop, the way a typed one "
                     + "does. Stops between sentences, question marks, exclamation marks and "
                     + "lists are left alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                Text("Words the transcriber tends to mangle. One per line.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $dictionary)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                Toggle("Bias the transcriber toward these words", isOn: $biasVocabulary)
                Text("Improves rare names, at the cost of occasionally inventing words in silence.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Replacements") {
                Text("Applied literally, before the layout pass. One per line, as wrong = right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $replacements)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .onAppear(perform: load)
    }

    /// The notice that a change is waiting on an engine restart.
    ///
    /// Its own section at the top of the pane rather than a permanently visible button, so
    /// a pane with nothing pending shows nothing, and so the sentence explaining why a
    /// restart is needed sits next to the button that performs it.
    @ViewBuilder
    private var pendingRestart: some View {
        if needsRestart || !status.isEmpty {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: noticeSymbol)
                        .foregroundStyle(noticeTint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(noticeTitle)
                            .font(.headline)
                        Text(noticeDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if needsRestart {
                        Button("Save and Restart") { save() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var noticeSymbol: String {
        if needsRestart { return "arrow.trianglehead.2.clockwise.rotate.90" }
        return statusIsFailure ? "exclamationmark.triangle" : "checkmark.circle"
    }

    private var noticeTint: Color {
        if needsRestart { return .orange }
        return statusIsFailure ? .red : .green
    }

    private var noticeTitle: String {
        if needsRestart { return "Changes are waiting" }
        return statusIsFailure ? "That did not work" : "Saved"
    }

    private var noticeDetail: String {
        guard needsRestart else { return status }
        return "The engine reads these once when it starts, so it has to be restarted "
            + "before they take effect."
    }




    private var outputExplanation: String {
        switch outputAction {
        case .insert: return "Typed where your cursor is."
        case .clipboard: return "Left on the clipboard for you to paste. Nothing is typed."
        case .both: return "Typed at the cursor and left on the clipboard, so Universal Clipboard "
            + "can carry it to your iPhone or iPad."
        }
    }

    /// The restart-requiring settings as the form currently shows them.
    private var current: EngineSettings {
        EngineSettings(dictionary: EngineSettings.words(fromText: dictionary),
                       biasVocabulary: biasVocabulary,
                       replacements: EngineSettings.replacements(fromText: replacements),
                       spokenLayout: spokenLayout)
    }

    /// True when a field the daemon only reads at startup differs from what was loaded.
    /// The app-side toggles are deliberately excluded, because they already applied.
    private var needsRestart: Bool {
        guard let loaded else { return false }
        return current != loaded
    }

    private func load() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        muteOthers = Settings.muteOthersWhileDictating
        casualInChat = Settings.casualInChat
        showInDock = Settings.showInDock
        guard let data = try? Data(contentsOf: Paths.config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let words = obj["dictionary"] as? [String] ?? []
        let pairs = obj["replacements"] as? [String: String] ?? [:]
        dictionary = EngineSettings.text(fromWords: words)
        replacements = EngineSettings.text(fromReplacements: pairs)
        biasVocabulary = obj["use_initial_prompt"] as? Bool ?? false
        outputAction = OutputAction.from(configValue: obj["output_action"] as? String)
        spokenLayout = obj["spoken_layout"] as? Bool ?? true
        loaded = current
    }

    /// Persist the settings and restart the engine, which prefills its prompt from these
    /// and so has to come back up before a change takes effect.
    private func save() {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.config),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj["use_initial_prompt"] = biasVocabulary
        obj["output_action"] = outputAction.rawValue
        obj["spoken_layout"] = spokenLayout
        obj["dictionary"] = EngineSettings.words(fromText: dictionary)
        obj["replacements"] = EngineSettings.replacements(fromText: replacements)

        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            status = "Could not write settings."
            statusIsFailure = true
            return
        }
        do {
            try data.write(to: Paths.config)
        } catch {
            status = error.localizedDescription
            statusIsFailure = true
            return
        }

        status = "Restarting the engine…"
        statusIsFailure = false
        loaded = current
        DispatchQueue.global().async {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "phonad.py"]
            try? kill.run()
            kill.waitUntilExit()
            let ok = DaemonClient.startAndWait()
            DispatchQueue.main.async {
                status = ok ? "The engine restarted, so the changes are live."
                            : "Written to config.json, but the engine did not come back up."
                statusIsFailure = !ok
            }
        }
    }
}
