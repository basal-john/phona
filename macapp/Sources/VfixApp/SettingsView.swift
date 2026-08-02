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
    @State private var status: String = ""

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

            Section("Replacements") {
                Text("Applied last, literally. One per line, as wrong = right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $replacements)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 62)
            }

            Section {
                Toggle("Open vfix at login", isOn: $launchAtLogin)
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

    private func load() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard let data = try? Data(contentsOf: Paths.config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        dictionary = (obj["dictionary"] as? [String] ?? []).joined(separator: "\n")
        biasVocabulary = obj["use_initial_prompt"] as? Bool ?? false
        insertAtCursor = (obj["output_action"] as? String ?? "insert") == "insert"
        let pairs = obj["replacements"] as? [String: String] ?? [:]
        replacements = pairs.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: "\n")
    }

    private func save() {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.config),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj["mode"] = mode.rawValue
        obj["use_initial_prompt"] = biasVocabulary
        obj["output_action"] = insertAtCursor ? "insert" : "clipboard"
        obj["dictionary"] = dictionary
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var pairs: [String: String] = [:]
        for line in replacements.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { pairs[key] = value }
        }
        obj["replacements"] = pairs

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

        // The daemon prefills its prompt from these, so it has to come back up to see them.
        status = "Saved. Restarting the engine…"
        DispatchQueue.global().async {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "vfixd.py"]
            try? kill.run()
            kill.waitUntilExit()
            let ok = DaemonClient.startAndWait()
            DispatchQueue.main.async { status = ok ? "Saved." : "Saved, but the engine did not restart." }
        }
    }
}
