import PhonaCore
import ServiceManagement
import SwiftUI

/// Real fields for the settings that previously meant hand-editing config.json.
struct SettingsView: View {
    @State private var mode: Mode = .current
    @State private var dictionary: String = ""
    @State private var replacements: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var biasVocabulary: Bool = false
    @State private var insertAtCursor: Bool = true
    @State private var spokenLayout: Bool = true
    @State private var muteOthers: Bool = true
    @State private var showInDock: Bool = true
    @State private var status: String = ""
    @State private var loaded: EngineSettings?

    var body: some View {
        Form {
            Section {
                Picker("Correction", selection: $mode) {
                    Text("Grammar").tag(Mode.grammar)
                    Text("Polish").tag(Mode.polish)
                    Text("Transcribe only").tag(Mode.raw)
                }
                .pickerStyle(.segmented)
                Text(modeExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("When done", selection: $insertAtCursor) {
                    Text("Insert at cursor").tag(true)
                    Text("Copy to clipboard").tag(false)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Vocabulary") {
                Text("Words the transcriber tends to mangle. One per line.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $dictionary)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 76)
                Toggle("Bias the transcriber toward these words", isOn: $biasVocabulary)
                Text("Improves rare names, at the cost of occasionally inventing words in silence.")
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

            Section("Replacements") {
                Text("Applied literally, before the layout pass. One per line, as wrong = right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $replacements)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 62)
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

            Section {
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
                        }
                    }
            }

            Section {
                HStack {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private var modeExplanation: String {
        switch mode {
        case .grammar: return "Fixes grammar and punctuation, keeps your wording."
        case .polish: return "Also removes filler words and splits run-on sentences."
        case .raw: return "No correction. Inserts exactly what was heard."
        }
    }

    /// The restart-requiring settings as the form currently shows them.
    private var current: EngineSettings {
        EngineSettings(mode: mode.rawValue,
                       dictionary: EngineSettings.words(fromText: dictionary),
                       biasVocabulary: biasVocabulary,
                       replacements: EngineSettings.replacements(fromText: replacements),
                       spokenLayout: spokenLayout)
    }

    private func load() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        muteOthers = Settings.muteOthersWhileDictating
        showInDock = Settings.showInDock
        guard let data = try? Data(contentsOf: Paths.config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let words = obj["dictionary"] as? [String] ?? []
        let pairs = obj["replacements"] as? [String: String] ?? [:]
        dictionary = EngineSettings.text(fromWords: words)
        replacements = EngineSettings.text(fromReplacements: pairs)
        biasVocabulary = obj["use_initial_prompt"] as? Bool ?? false
        insertAtCursor = (obj["output_action"] as? String ?? "insert") == "insert"
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
        obj["mode"] = mode.rawValue
        obj["use_initial_prompt"] = biasVocabulary
        obj["output_action"] = insertAtCursor ? "insert" : "clipboard"
        obj["spoken_layout"] = spokenLayout
        obj["dictionary"] = EngineSettings.words(fromText: dictionary)
        obj["replacements"] = EngineSettings.replacements(fromText: replacements)

        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            status = "Could not write settings."
            return
        }
        do {
            try data.write(to: Paths.config)
        } catch {
            status = error.localizedDescription
            return
        }

        status = "Saved. Restarting the engine…"
        DispatchQueue.global().async {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "phonad.py"]
            try? kill.run()
            kill.waitUntilExit()
            let ok = DaemonClient.startAndWait()
            DispatchQueue.main.async { status = ok ? "Saved." : "Saved, but the engine did not restart." }
        }
    }
}
