import PhonaCore
import SwiftUI

/// The pane that answers the only question the window exists to answer: was any of this
/// worth it.
///
/// The hero figure carries its own arithmetic underneath, in plain words, because a claim
/// about hours saved is worthless unless the reader can check it. Every input to it is on
/// screen: the word count, the typing speed it was divided by, and the time actually spent
/// speaking that was subtracted.
struct HomeView: View {
    @ObservedObject var store: HistoryStore
    let showAll: () -> Void

    /// Speeds a picker can offer without pretending to precision. A speaker who knows their
    /// own rate to the word is not served by a slider either.
    private static let typingSpeeds: [Double] = [25, 30, 35, 40, 45, 50, 55, 60, 70, 80, 100]

    private var insights: Insights { store.insights }

    var body: some View {
        Group {
            if store.rows.isEmpty {
                EmptyPane(symbol: "waveform",
                          title: store.hasHistoryFile ? "No dictations yet" : "No history file yet",
                          detail: store.hasHistoryFile
                              ? "Hold either Option key and speak. Everything you dictate lands here."
                              : "The engine writes history.jsonl the first time it delivers a dictation.")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            hero
                            tiles.frame(width: 250)
                        }
                        activity
                        latest
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                }
            }
        }
    }

    private var hero: some View {
        Card("Typing time avoided") {
            VStack(alignment: .leading, spacing: 6) {
                heroFigure
                Text(arithmetic)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                typingSpeedPicker
            }
        }
    }

    @ViewBuilder
    private var heroFigure: some View {
        let saved = Figures.hoursAndMinutes(fromMinutes: insights.minutesSaved)
        if insights.minutesSaved > 0 {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text("\(saved.hours)")
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                Text("h").font(.title3).foregroundStyle(.secondary)
                Text("\(saved.minutes)")
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                Text("m").font(.title3).foregroundStyle(.secondary)
            }
        } else {
            Text("Nothing yet at this speed")
                .font(.title2.weight(.semibold))
        }
    }

    /// The subtraction, in words, exactly as it was performed.
    ///
    /// `spokenWords` rather than `words`, because those are the words the division above used.
    /// A typed correction is text somebody already typed, so it avoided no typing and belongs
    /// on neither side of this.
    private var arithmetic: String {
        let toType = Figures.decimal(insights.minutesToType)
        let spoken = Figures.decimal(insights.minutesSpoken)
        let words = Figures.integer(insights.spokenWords)
        let rate = Figures.decimal(insights.typingWordsPerMinute, places: 0)
        return "\(toType) min to type the \(words) words you spoke at \(rate) wpm\n"
            + "less \(spoken) min actually spoken"
    }

    private var typingSpeedPicker: some View {
        Picker("Typing speed", selection: Binding(
            get: { selectedSpeed },
            set: { store.setTypingWordsPerMinute($0) })) {
            ForEach(offeredSpeeds, id: \.self) { speed in
                Text("\(Figures.decimal(speed, places: 0)) wpm").tag(speed)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 110)
        .controlSize(.small)
    }

    /// The stored speed is offered alongside the presets, so a hand-edited config.json value
    /// is not silently rounded to whatever preset happens to be nearest.
    ///
    /// Read off the snapshot rather than off `insights`, because the recompute now runs on a
    /// background queue and the picker has to show the chosen speed the moment it is chosen.
    private var offeredSpeeds: [Double] {
        Array(Set(HomeView.typingSpeeds + [selectedSpeed])).sorted()
    }

    private var selectedSpeed: Double {
        store.snapshot.typingWordsPerMinute
    }

    private var tiles: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Figures.integer(insights.today.count))
                            .font(.system(size: 26, weight: .semibold))
                            .monospacedDigit()
                        Text("Today").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("\(insights.currentStreak)")
                                .font(.system(size: 26, weight: .semibold))
                                .monospacedDigit()
                            Text("d").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Streak · best \(insights.bestStreak)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Card("Words delivered") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(Figures.integer(insights.words))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text(spokenRate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(spokenShare)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Absent rather than zero when nothing in the history can carry a rate. A history of
    /// typed FIX rows has no speaking time in it, and printing "0.0 wpm" would read as a
    /// measurement of very slow speech.
    private var spokenRate: String {
        insights.spokenWordsPerMinute > 0
            ? "at \(Figures.decimal(insights.spokenWordsPerMinute)) wpm spoken"
            : "no speaking time recorded"
    }

    private var spokenShare: String {
        let spoken = insights.spokenDictations
        let total = insights.dictations
        guard total > spoken else {
            return "over \(Figures.integer(total)) dictations"
        }
        return "over \(Figures.integer(total)) dictations, \(Figures.integer(spoken)) of them spoken"
    }

    private var activity: some View {
        Card("Activity", trailing: activityRange) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(insights.days, id: \.day) { day in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.count > 0 ? Palette.activity.opacity(opacity(day)) : Color.secondary.opacity(0.18))
                            .frame(height: height(day))
                            .frame(maxWidth: 11)
                            .help("\(Figures.shortDay(day.day)) · \(day.count) dictations, \(Figures.integer(day.words)) words")
                    }
                }
                .frame(height: 54, alignment: .bottom)

                HStack {
                    Text(insights.days.first.map { Figures.shortDay($0.day) } ?? "")
                    Spacer()
                    if let peak, peak.count > 0 {
                        Text("\(Figures.shortDay(peak.day)) · \(peak.count)")
                    }
                    Spacer()
                    Text(insights.days.last.map { Figures.shortDay($0.day) } ?? "")
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var peak: DaySummary? {
        insights.days.max { $0.count < $1.count }
    }

    private var activityRange: String {
        let active = insights.days.filter { $0.count > 0 }.count
        return "\(insights.days.count) days · \(active) active"
    }

    /// A bar is never shorter than a hairline, so a day with one dictation is visibly
    /// different from a day with none rather than both rendering as nothing.
    private func height(_ day: DaySummary) -> CGFloat {
        let top = max(peak?.count ?? 0, 1)
        guard day.count > 0 else { return 2 }
        return max(3, 54 * CGFloat(day.count) / CGFloat(top))
    }

    /// Colour carries the same figure the height does, so a busy day reads as busy even
    /// where a run of tall bars flattens the eye's sense of the scale.
    private func opacity(_ day: DaySummary) -> Double {
        let top = max(peak?.count ?? 0, 1)
        return 0.45 + 0.55 * Double(day.count) / Double(top)
    }

    private var latest: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Latest")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show all", action: showAll)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ForEach(Array(store.descending.prefix(6).enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                LatestRow(row: row)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

/// One line of the Latest list, carrying its route dot like every other place a dictation
/// appears in this window.
private struct LatestRow: View {
    let row: HistoryRow

    var body: some View {
        HStack(spacing: 11) {
            Text(Figures.clock(row.ts))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .leading)
            RouteDot(route: row.route, diameter: 5)
            Text(Figures.flatten(row.text))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            latency
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var seconds: Double { row.sttSecs + row.llmSecs }

    /// A slow dictation is marked, because the whole point of showing latency here is that a
    /// figure nobody notices is a figure nobody acts on.
    @ViewBuilder
    private var latency: some View {
        if seconds > Insights.slowSeconds {
            Chip(text: Figures.latency(seconds), tint: Palette.slow)
        } else if seconds > 0 {
            Text(Figures.latency(seconds))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
