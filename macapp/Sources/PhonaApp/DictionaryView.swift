import PhonaCore
import SwiftUI

/// The words the speaker has taught Phona, and what they are actually for.
///
/// Read-only in this pass. Editing already exists in the Settings window's Words tab, which
/// writes config.json and restarts the engine, and a second editor over the same file would
/// be a way to lose a list rather than a convenience.
///
/// The pane leads with whether these words reach the transcriber, because the obvious
/// reading of a dictionary is that it changes what is heard, and on the default speech model
/// it cannot. Which of the three answers applies is read off the live config rather than
/// assumed, because two settings decide it and both are changeable.
struct DictionaryView: View {
    @ObservedObject var store: HistoryStore

    private var words: [String] { store.snapshot.dictionary }

    /// Sorted, so reopening the pane does not reorder the list under the reader. The stored
    /// order is the order words were added, which is meaningful to nobody.
    private var pairs: [(heard: String, becomes: String)] {
        store.snapshot.replacements
            .map { (heard: $0.key, becomes: $0.value) }
            .sorted { $0.heard.localizedCaseInsensitiveCompare($1.heard) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                honesty
                if words.isEmpty && pairs.isEmpty {
                    EmptyPane(symbol: "book.closed",
                              title: "No words yet",
                              detail: "Add words and replacement pairs in the Words tab of Settings.")
                        .frame(minHeight: 240)
                } else {
                    wordList
                    replacements
                }
                Text("Both lists are edited in the Words tab of Settings, which restarts the "
                    + "engine because the daemon reads config.json once at startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
    }

    /// The note the mock-up leads with, and the reason the pane exists in this shape.
    private var honesty: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .fontWeight(.semibold)
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    /// Which of the three answers this Mac is actually in, from the loaded speech model and
    /// the `use_initial_prompt` flag together.
    private var reach: DictionaryReach {
        DictionaryReach.resolve(sttModel: store.snapshot.sttModel,
                                useInitialPrompt: store.snapshot.useInitialPrompt)
    }

    private var headline: String {
        switch reach {
        case .modelTakesNoHint, .hintAvailableButOff:
            return "On \(speechModelName) these words never reach the transcriber."
        case .hintInUse:
            return "On \(speechModelName) these words are fed to the transcriber."
        }
    }

    /// Each answer names what would change it, because the previous version of this note
    /// offered a remedy that does nothing on its own.
    private var explanation: String {
        let uses = "Your words keep a term intact once it has been heard, and stop the guard "
            + "rejecting a name it does not recognise."
        switch reach {
        case .modelTakesNoHint:
            return "This speech model accepts no vocabulary hint at all. " + uses
                + " To bias what is heard in the first place, switch speech to a Whisper "
                + "model in Models and turn on use_initial_prompt in config.json. Neither "
                + "one does it alone."
        case .hintAvailableButOff:
            return "Whisper can take a vocabulary hint, and use_initial_prompt is off, which "
                + "is the default, so the daemon hands it none. " + uses
                + " To bias what is heard in the first place, set use_initial_prompt to true "
                + "in config.json and restart the engine."
        case .hintInUse:
            return "Whisper is loaded and use_initial_prompt is on, so the daemon passes this "
                + "whole list as the initial prompt and it does bias what is heard. " + uses
        }
    }

    /// The configured model rather than a hardcoded name, because the claim above is only
    /// true of the model that is actually loaded.
    private var speechModelName: String {
        guard let model = store.snapshot.sttModel else { return "the default speech model" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    private var wordList: some View {
        Card("Words to keep intact", trailing: "\(Figures.integer(words.count)) words") {
            if words.isEmpty {
                Text("None yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowRow(words: words.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            }
        }
    }

    private var replacements: some View {
        Card("Always fix",
             trailing: "applied literally, before anything else · \(Figures.integer(pairs.count)) pairs") {
            if pairs.isEmpty {
                Text("None yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Heard as").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Becomes").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                    ForEach(pairs, id: \.heard) { pair in
                        HStack {
                            Text(pair.heard)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(pair.becomes)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }
}

/// The word list as wrapping chips rather than one word per line.
///
/// Thirty-two words down a single column is most of a window of scrolling for a list whose
/// only job is to be skimmed for something missing.
private struct FlowRow: View {
    let words: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 5) {
                    ForEach(line, id: \.self) { word in
                        Text(word)
                            .font(.callout)
                            .textSelection(.enabled)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Packed by estimated width rather than measured, because a real flow layout needs a
    /// `Layout` and the only cost of guessing here is a slightly ragged right edge.
    private var rows: [[String]] {
        let budget = 62
        var lines: [[String]] = []
        var line: [String] = []
        var used = 0
        for word in words {
            let cost = word.count + 3
            if used + cost > budget, !line.isEmpty {
                lines.append(line)
                line = []
                used = 0
            }
            line.append(word)
            used += cost
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
