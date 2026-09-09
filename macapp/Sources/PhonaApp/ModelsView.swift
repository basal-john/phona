import PhonaCore
import SwiftUI

/// A model Phona can be switched to, as `switch-model.sh` defines it.
///
/// The catalogue is taken from that script rather than restated, because the script is what
/// actually performs a switch and a second list would drift out of step with it. The notes
/// are its own one-line descriptions, so nothing here claims a figure the repo cannot show.
private struct ModelChoice: Identifiable {
    let flag: String
    let repository: String
    let note: String

    var id: String { repository }

    /// The last path component, which is what a reader recognises. The org prefix is the
    /// same for every one of them and only costs column width.
    var name: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}

/// What is running, what else could run, and what the record says about them.
///
/// Read-only in this pass. Switching a model rewrites config.json, restarts the engine, waits
/// for it to report ready and rolls back when it does not, all of which `switch-model.sh`
/// already does. A button that did the first half and not the rollback would be worse than
/// no button.
struct ModelsView: View {
    @ObservedObject var store: HistoryStore

    private static let corrections: [ModelChoice] = [
        ModelChoice(flag: "8bit",
                    repository: "mlx-community/Qwen3-4B-Instruct-2507-8bit",
                    note: "29 of 29 on the suite, slower on long dictation"),
        ModelChoice(flag: "4bit",
                    repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
                    note: "28 of 29, the fastest"),
        ModelChoice(flag: "8b",
                    repository: "mlx-community/Qwen3-8B-4bit",
                    note: "28 of 29, no better and larger"),
        ModelChoice(flag: "qwen35",
                    repository: "mlx-community/Qwen3.5-4B-8bit",
                    note: "the successor to the current model"),
        ModelChoice(flag: "gemma4",
                    repository: "mlx-community/gemma-4-e4b-it-8bit",
                    note: "the size-matched rival"),
    ]

    private static let speech: [ModelChoice] = [
        ModelChoice(flag: "parakeet",
                    repository: "mlx-community/parakeet-tdt-0.6b-v3",
                    note: "the default, takes no dictionary hint"),
        ModelChoice(flag: "whisper",
                    repository: "mlx-community/whisper-large-v3-turbo",
                    note: "slower, and the only speech model your words can bias"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                correction
                cloud
                speechSection
                switching
            }
            .padding(20)
        }
    }

    private var correction: some View {
        Card("Correction · left ⌥", trailing: "always on this Mac") {
            VStack(spacing: 0) {
                headerRow
                ForEach(ModelsView.corrections) { choice in
                    Divider()
                    row(choice)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("Your usage").frame(width: 210, alignment: .leading)
            Text("").frame(width: 74, alignment: .trailing)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    private func row(_ choice: ModelChoice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name).textSelection(.enabled)
                Text(choice.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            usage(for: choice)
                .frame(width: 210, alignment: .leading)

            Group {
                if store.snapshot.llmModel == choice.repository {
                    Chip(text: "in use", tint: Palette.route(.local))
                } else {
                    Text(choice.flag)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    /// What the history says about this model, or a plain admission that it says nothing.
    ///
    /// `llm_model` is new in this release, so every row written before it carries no model
    /// identity and is skipped rather than pooled under an invented name. That means an empty
    /// figure here is the normal state on the day this ships, and rendering it as zeros would
    /// read as a model that has corrected nothing and guarded nothing.
    @ViewBuilder
    private func usage(for choice: ModelChoice) -> some View {
        if let usage = store.insights.perModel.first(where: { $0.llmModel == choice.repository }) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Figures.integer(usage.count)) dictations")
                    .font(.caption)
                    .monospacedDigit()
                Text("median \(Figures.latency(usage.medianLatency)), "
                    + "\(Figures.integer(usage.guardedCount)) guarded")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("no data yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var cloud: some View {
        Card("Correction · right ⌥", trailing: "leaves this Mac") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RouteDot(route: .cloud)
                    /// The model the daemon reports, which is the file's value where it has
                    /// one and the daemon's default otherwise. This line used to read the
                    /// file alone and so announced that no cloud model was configured on
                    /// every default install, including while the cloud was correcting.
                    Text(store.snapshot.cloudModel ?? "no cloud model is configured")
                        .textSelection(.enabled)
                    if let backend = store.snapshot.cloudBackend {
                        Text("via \(backend)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(Figures.integer(store.insights.routeCounts[.cloud] ?? 0)) sent")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text("Speech stays on this Mac either way. Only the correction step is sent, "
                    + "and a cloud correction that fails the guards falls back to the local "
                    + "model rather than being pasted. The count is dictations whose "
                    + "transcript went, so it includes the ones this model did not end up "
                    + "correcting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var speechSection: some View {
        Card("Speech · both keys, always on this Mac") {
            VStack(spacing: 0) {
                ForEach(Array(ModelsView.speech.enumerated()), id: \.offset) { index, choice in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name).textSelection(.enabled)
                            Text(choice.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Group {
                            if store.snapshot.sttModel == choice.repository {
                                Chip(text: "in use", tint: Palette.route(.local))
                            } else {
                                Text(choice.flag)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 74, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var switching: some View {
        Card("Switching") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Run ~/.local/share/phona/switch-model.sh with the short name from the "
                    + "right hand column, for example switch-model.sh 4bit. Both install.sh "
                    + "and update.sh copy it there, so that path works whether Phona was "
                    + "installed or cloned. It rewrites config.json, restarts the engine, "
                    + "waits for it to report ready, and rolls the change back if it does not.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("~/.local/share/phona/switch-model.sh with no argument prints what is "
                    + "running now.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
