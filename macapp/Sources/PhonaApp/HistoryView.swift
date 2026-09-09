import AppKit
import PhonaCore
import SwiftUI

/// One dictation, tagged so a list can select it.
///
/// `HistoryRow` is deliberately not `Identifiable`: two rows a second apart can share a
/// timestamp, so a stamp is not an identity. The index into the loaded array is, for as long
/// as that load is on screen, and a reload clears the selection rather than moving it. That
/// clearing is `store.loadToken`, watched below, without which a reload leaves the index
/// pointing at whichever row has slid into that slot.
private struct Dictation: Identifiable, Equatable {
    let id: Int
    let row: HistoryRow
}

/// What the speaker is looking for, when they are looking for less than everything.
///
/// Internal rather than private because the filter is a toolbar control, and a toolbar can
/// be hidden or customised, so every one of these has to also be a menu command.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case cloud
    case guarded
    case flagged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .local: return "On this Mac"
        case .cloud: return "Left this Mac"
        case .guarded: return "Guard stepped in"
        case .flagged: return "You flagged"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .local: return "laptopcomputer"
        case .cloud: return "arrow.up.circle"
        case .guarded: return "shield.lefthalf.filled"
        case .flagged: return "flag"
        }
    }

    var tint: Color? {
        switch self {
        case .all: return nil
        case .local: return Palette.route(.local)
        case .cloud: return Palette.route(.cloud)
        case .guarded: return Palette.guarded
        case .flagged: return Palette.flagged
        }
    }
}

/// The pane whose whole purpose is getting text back out of the record.
///
/// A master list grouped by day beside a detail pane that shows what was heard next to what
/// was delivered. Those two being side by side is the only way to tell a mishearing from a
/// bad correction, which is the question anyone opening this pane is actually asking.
struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    /// Held by the window rather than here, so the same filter is on the toolbar and in the
    /// View menu and the two cannot disagree.
    @Binding var filter: HistoryFilter
    let flag: () -> Void

    @State private var query = ""
    @State private var selection: Int?

    var body: some View {
        Group {
            if store.rows.isEmpty {
                EmptyPane(symbol: "clock",
                          title: "Nothing in the history yet",
                          detail: "Every dictation is written to history.jsonl as it is delivered.")
            } else {
                /// A split view rather than an `HStack` of a fixed 330pt list and a divider.
                /// The platform reflows a split view continuously as the window resizes and
                /// lets the reader drag the boundary to whichever side they are working on,
                /// which a hard-coded width cannot do.
                HSplitView {
                    master
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: 480)
                        .frame(maxHeight: .infinity)
                    detail
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
                /// `HSplitView` takes its height from its content unless it is told to
                /// fill, and a list of two rows is content, so without this the whole pane
                /// collapsed to a couple of rows floating in the middle of the window.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: store.loadToken) { selection = nil }
            }
        }
        /// The system search field, in the toolbar where macOS puts search, instead of a
        /// `TextField` inside a hand-drawn rounded rectangle with its own magnifying glass.
        /// What that hand-built version did not have: the focus ring, the clear button,
        /// Command-F, the token and recent-search behaviour, and a VoiceOver role that says
        /// "search field".
        .searchable(text: $query,
                    placement: .toolbar,
                    prompt: "What was heard or delivered")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                filterPicker
            }
        }
    }

    /// The filter, as a pull-down that says what it is set to.
    ///
    /// A `Picker` in a toolbar draws only the selected item's symbol, which reads as an
    /// empty control with a mystery glyph in it. A `Menu` with an explicit label shows the
    /// current filter by name, and a check beside the chosen row, so the control answers
    /// "what am I looking at" without being opened.
    private var filterPicker: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(HistoryFilter.allCases) { option in
                    Label("\(option.title)  ·  \(Figures.integer(count(for: option)))",
                          systemImage: option.symbol)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(filter.title, systemImage: filter.symbol)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Show only some of the history")
    }

    /// Live, and over the whole history rather than over the current search, because a count
    /// that moves with the search box cannot answer "how many did the guard ever catch".
    private func count(for option: HistoryFilter) -> Int {
        switch option {
        case .all: return store.rows.count
        case .local: return store.insights.routeCounts[.local] ?? 0
        case .cloud: return store.insights.routeCounts[.cloud] ?? 0
        case .guarded: return store.insights.guardedCount
        case .flagged: return store.snapshot.flaggedRowCount
        }
    }

    private var items: [Dictation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.descending.enumerated().compactMap { index, row in
            guard matches(row) else { return nil }
            if !needle.isEmpty {
                let heard = row.raw.lowercased()
                let delivered = row.text.lowercased()
                let actual = store.correction(for: row)?.actual?.lowercased() ?? ""
                guard heard.contains(needle) || delivered.contains(needle)
                    || actual.contains(needle) else { return nil }
            }
            return Dictation(id: index, row: row)
        }
    }

    private func matches(_ row: HistoryRow) -> Bool {
        switch filter {
        case .all: return true
        case .local: return row.route == .local
        case .cloud: return row.route == .cloud
        case .guarded: return row.guarded
        case .flagged: return store.isFlagged(row)
        }
    }

    /// Newest day first, and newest dictation first inside each day, which is the order the
    /// list already arrives in. Grouped rather than sorted again so the two cannot disagree.
    private var days: [(day: Date, items: [Dictation])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [Dictation]] = [:]
        for item in items {
            let key = calendar.startOfDay(for: item.row.ts)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private var master: some View {
        Group {
            if items.isEmpty {
                EmptyPane(symbol: "line.3.horizontal.decrease",
                          title: "Nothing matches",
                          detail: "No dictation in the history matches this search and filter.")
            } else {
                List(selection: $selection) {
                    ForEach(days, id: \.day) { group in
                        Section(Figures.day(group.day)) {
                            ForEach(group.items) { item in
                                MasterRow(row: item.row, flagged: store.isFlagged(item.row))
                                    .tag(item.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var selectedRow: HistoryRow? {
        guard let selection, store.descending.indices.contains(selection) else { return nil }
        return store.descending[selection]
    }

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            DetailPane(row: row,
                       correction: store.correction(for: row),
                       medianLatency: store.insights.latency.p50,
                       canFlag: store.canFlag(row),
                       flag: flag)
        } else {
            EmptyPane(symbol: "text.alignleft",
                      title: "Pick a dictation",
                      detail: "The detail shows what Phona heard beside what it delivered, which is how you tell a mishearing from a bad correction.")
        }
    }
}

/// One row of the master list.
private struct MasterRow: View {
    let row: HistoryRow
    let flagged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(Figures.clock(row.ts))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                RouteDot(route: row.route)
                RouteBadge(route: row.route)
                if row.guarded { Chip(text: "guard", tint: Palette.guarded) }
                if row.trimmed { Chip(text: "trimmed", tint: Palette.slow) }
                if flagged { Chip(text: "flagged", tint: Palette.flagged) }
                Spacer(minLength: 4)
                Text(Figures.latency(row.sttSecs + row.llmSecs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(Figures.flatten(row.text))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}

/// The detail pane. Heard, delivered, and where the two came from.
private struct DetailPane: View {
    let row: HistoryRow
    let correction: Correction?
    let medianLatency: Double
    let canFlag: Bool
    let flag: () -> Void

    @State private var copied = false

    private var seconds: Double { row.sttSecs + row.llmSecs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                stamp
                block("What Phona heard", text: row.raw.isEmpty ? "nothing was recorded" : row.raw,
                      emphasised: false)
                block("What it delivered", text: row.text, emphasised: true)
                if let actual = correction?.actual {
                    block("What you actually said", text: actual, emphasised: true)
                }
                if row.guarded { note(guardNote, symbol: "shield.lefthalf.filled") }
                if row.trimmed { note(trimNote, symbol: "scissors") }
                if seconds > Insights.slowSeconds { note(slowNote, symbol: "clock.badge.exclamationmark") }
                provenance
                actions
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stamp: some View {
        HStack(spacing: 8) {
            Text(Figures.stamp(row.ts))
                .font(.headline)
                .monospacedDigit()
            RouteDot(route: row.route)
            Text(routeLabel)
                .font(.callout)
                .foregroundStyle(Palette.route(row.route))
        }
    }

    /// What happened to the text, and then whose correction landed.
    ///
    /// `route` answers the first off `cloud_sent`, whether the transcript was handed to a
    /// cloud process. `backend` answers the second, whose reply was used. A row that reads
    /// sent with no backend is one the cloud saw and did not correct, which is what a
    /// refused or failed cloud request leaves behind and is the reason these are two fields.
    /// The third case is a right-Option dictation where nothing was ever sent, because the
    /// agent CLI was not installed.
    private var routeLabel: String {
        if row.route == .cloud {
            return row.backend == nil
                ? "left this Mac, then corrected on it"
                : "left this Mac and was corrected there"
        }
        if row.mode == "cloud" { return "cloud asked for, nothing was sent" }
        return "never left this Mac"
    }

    /// One of the three texts, in the container the platform draws for grouped content.
    ///
    /// The delivered text is the one a reader came here to copy, so it keeps the text
    /// background and the primary label colour, and the heard text sits in a plain group
    /// beside it. Both used to be hand-painted rounded rectangles with a quaternary stroke,
    /// at a 7pt radius that no longer matches anything the system draws.
    private func block(_ title: String, text: String, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .textSelection(.enabled)
                .foregroundStyle(emphasised ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(emphasised ? AnyShapeStyle(.background)
                                       : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// A remark about this dictation, in the shape the system uses for an inline notice.
    ///
    /// The symbol is decorative here, because the sentence beside it already says what it
    /// means, so it is hidden from VoiceOver rather than read out as "clock badge
    /// exclamation mark" before the sentence that explains it.
    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.slow)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.slow.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Which of the three things the guard can leave behind actually landed.
    ///
    /// The engine has no path that hands back the transcript verbatim, so the note never
    /// says it does. What it can leave is the local model's second attempt, a mechanical
    /// tidy of the transcript when that was refused as well, or, on the cloud path, the
    /// local model's ordinary correction.
    ///
    /// The reason string is the only record of which, and its shape is the tell.
    /// `_correct_one` writes a bare reason. `correct_cloud` prefixes `cloud <backend>:` when
    /// it throws the cloud reply away, and appends `; local:` on top of that when the local
    /// model it fell back to was refused too. No local reason begins with the word cloud.
    private var guardNote: String {
        let localOutcome = "what landed is its second attempt, or the transcript with its "
            + "capitals and full stops put back mechanically if that was refused too"
        guard let reason = row.guardReason else {
            return "The guard rejected a correction on this dictation. No reason was "
                + "recorded on the row, so which stage it was cannot be read back."
        }
        if reason.hasPrefix("cloud ") {
            if reason.contains("; local: ") {
                return "The cloud correction was not used, and the local model that took "
                    + "over was rejected as well, so \(localOutcome). Reason: \(reason)."
            }
            return "The cloud correction was not used, so the local model corrected this "
                + "one instead and its reply is what landed. Reason: \(reason)."
        }
        return "The local model's first reply was rejected, so \(localOutcome). "
            + "Reason: \(reason)."
    }

    private var trimNote: String {
        "The transcriber looped and a repeated tail was cut off the end, so what landed is "
            + "shorter than what was said."
    }

    /// Names the two stages, because when both are slow together the machine was short of
    /// memory and when only one is, the model is the story. A single total cannot say which.
    private var slowNote: String {
        let comparison = medianLatency > 0
            ? " The usual is \(Figures.latency(medianLatency))."
            : ""
        return "\(Figures.latency(seconds)) in all. Speech took \(Figures.latency(row.sttSecs)) "
            + "and correction \(Figures.latency(row.llmSecs))."
            + comparison
            + " Both slowing together means the machine, not the models."
    }

    private var provenance: some View {
        Card("How it was produced") {
            VStack(alignment: .leading, spacing: 6) {
                field("Speech", row.sttModel ?? "not recorded")
                field("Correction", correctionModel)
                field("Latency", "\(Figures.latency(seconds)) total, "
                    + "\(Figures.latency(row.sttSecs)) speech, \(Figures.latency(row.llmSecs)) correction")
                if row.isSpoken {
                    field("Spoken for", Figures.latency(row.seconds))
                } else {
                    field("Spoken for", "not spoken, this row came from a typed correction")
                }
                field("Words delivered", Figures.integer(row.wordCount))
            }
        }
    }

    /// The cloud model when the cloud answered, the local one otherwise, and a plain refusal
    /// to guess for rows written before the engine recorded either.
    ///
    /// Off `backend` rather than `route`, because `route` now reports a transcript that was
    /// sent and refused as having left this Mac, and naming the cloud model on that row
    /// would credit a reply that was thrown away.
    private var correctionModel: String {
        if row.backend != nil, let cloud = row.cloudModel { return cloud }
        if let local = row.llmModel { return local }
        return "not recorded, this row predates model identity in the history"
    }

    /// A label and its value, laid out by `LabeledContent`.
    ///
    /// It was an `HStack` with the label boxed at a hard 110pt, which is a guess at the
    /// widest of five labels that breaks the moment a longer one is added or the pane is
    /// narrowed. `LabeledContent` is the component for this and aligns the pair the way
    /// every form on the platform does, and it reads to VoiceOver as one label-value pair
    /// rather than as two unrelated strings.
    private func field(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                /// The reason a reader opens this pane is to get the text back out, so the
                /// copy is the default button rather than one of two equal ones.
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copy()
                }
                .buttonStyle(.borderedProminent)

                /// An ellipsis, because it opens an alert that asks for more. That is what
                /// a trailing ellipsis promises everywhere else on the system.
                Button("Mark as Wrong…", systemImage: "flag", action: flag)
                    .disabled(!canFlag)
            }
            if !canFlag {
                Text("Only the most recent dictation can be flagged. The engine's FLAG command "
                    + "reads the last line of the history and has no way to name an older one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
