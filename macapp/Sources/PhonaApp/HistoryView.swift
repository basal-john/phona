import AppKit
import PhonaCore
import SwiftUI

/// One dictation, tagged so a list can select it.
///
/// `HistoryRow` is deliberately not `Identifiable`: two rows a second apart can share a
/// timestamp, so a stamp is not an identity. The index into the loaded array is, for as long
/// as that load is on screen, and a reload clears the selection rather than moving it.
private struct Dictation: Identifiable, Equatable {
    let id: Int
    let row: HistoryRow
}

/// What the speaker is looking for, when they are looking for less than everything.
private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case cloud
    case guarded
    case flagged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .local: return "On-device"
        case .cloud: return "Cloud"
        case .guarded: return "Guard stepped in"
        case .flagged: return "You flagged"
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
    let flag: () -> Void

    @State private var query = ""
    @State private var filter: HistoryFilter = .all
    @State private var selection: Int?

    var body: some View {
        Group {
            if store.rows.isEmpty {
                EmptyPane(symbol: "clock",
                          title: "Nothing in the history yet",
                          detail: "Every dictation is written to history.jsonl as it is delivered.")
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    HStack(spacing: 0) {
                        master.frame(width: 330)
                        Divider()
                        detail.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search what was heard or delivered", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .frame(width: 250)

            Spacer(minLength: 8)

            Picker("Filter", selection: $filter) {
                ForEach(HistoryFilter.allCases) { option in
                    Text("\(option.title)  \(Figures.integer(count(for: option)))").tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 210)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// Live, and over the whole history rather than over the current search, because a count
    /// that moves with the search box cannot answer "how many did the guard ever catch".
    private func count(for option: HistoryFilter) -> Int {
        switch option {
        case .all: return store.rows.count
        case .local: return store.insights.routeCounts[.local] ?? 0
        case .cloud: return store.insights.routeCounts[.cloud] ?? 0
        case .guarded: return store.insights.guardedCount
        case .flagged: return store.snapshot.corrections.count
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(Figures.clock(row.ts))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                RouteDot(route: row.route, diameter: 5)
                RouteBadge(route: row.route)
                if row.guarded { Chip(text: "guard", tint: Palette.guarded) }
                if row.trimmed { Chip(text: "trimmed", tint: Palette.slow) }
                if flagged { Chip(text: "flagged", tint: Palette.flagged) }
                Spacer(minLength: 4)
                Text(Figures.latency(row.sttSecs + row.llmSecs))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            RouteDot(route: row.route)
            Text(row.route == .local ? "left ⌥ · on-device" : "right ⌥ · cloud")
                .font(.system(size: 10))
                .foregroundStyle(Palette.route(row.route))
        }
    }

    private func block(_ title: String, text: String, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .foregroundStyle(emphasised ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: emphasised ? .textBackgroundColor : .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.slow)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.slow.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.slow.opacity(0.3)))
    }

    private var guardNote: String {
        let reason = row.guardReason ?? "no reason was recorded"
        return "The guard rejected the correction and delivered the transcript instead. Reason: \(reason)."
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
    private var correctionModel: String {
        if row.route == .cloud, let cloud = row.cloudModel { return cloud }
        if let local = row.llmModel { return local }
        return "not recorded, this row predates model identity in the history"
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy") { copy() }
                Button("Mark as wrong", action: flag)
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
