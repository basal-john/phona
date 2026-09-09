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
                        /// Side by side while there is room, stacked when there is not.
                        /// It was an `HStack` of a growing card beside a hard 250pt column,
                        /// and below about 760pt of pane the two squeezed into each other.
                        /// The platform now expects a window to be draggable to any width
                        /// with the content reflowing rather than compressing.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                hero
                                tiles.frame(width: 260)
                            }
                            VStack(spacing: 16) {
                                hero
                                tiles
                            }
                        }
                        activity
                        latest
                    }
                    .padding(20)
                }
            }
        }
    }

    private var hero: some View {
        Card("Typing time avoided") {
            VStack(alignment: .leading, spacing: 10) {
                heroFigure
                Text(arithmetic)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                typingSpeedPicker
            }
        }
    }

    /// The figure, and the same figure as one sentence for VoiceOver.
    ///
    /// Four separate labels on a baseline read out as "6", "h", "40", "m", which is not a
    /// duration. The stack is one accessibility element saying what it means, and the
    /// pieces underneath are hidden so they are not read twice.
    @ViewBuilder
    private var heroFigure: some View {
        let saved = Figures.hoursAndMinutes(fromMinutes: insights.minutesSaved)
        if insights.minutesSaved > 0 {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text("\(saved.hours)")
                    .font(Display.hero)
                    .monospacedDigit()
                Text("h").font(.title3).foregroundStyle(.secondary)
                Text("\(saved.minutes)")
                    .font(Display.hero)
                    .monospacedDigit()
                Text("m").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Typing time avoided")
            .accessibilityValue("\(saved.hours) hours \(saved.minutes) minutes")
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
        .fixedSize()
        .accessibilityLabel("Typing speed the figure above is divided by")
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
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Figures.integer(insights.today.count))
                            .font(Display.tile)
                            .monospacedDigit()
                        Text("Today").font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Dictations today")
                    .accessibilityValue(Figures.integer(insights.today.count))
                }
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("\(insights.currentStreak)")
                                .font(Display.tile)
                                .monospacedDigit()
                            Text("d").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Streak · best \(insights.bestStreak)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Streak")
                    .accessibilityValue("\(insights.currentStreak) days, best \(insights.bestStreak)")
                }
            }
            Card("Words delivered") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(Figures.integer(insights.words))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text(spokenRate)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(spokenShare)
                        .font(.callout)
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

    /// The last five weeks as one bar a day.
    ///
    /// Every bar used to carry a tooltip and nothing else, so the whole chart was invisible
    /// to VoiceOver and to anyone driving the app from the keyboard. Each bar is now a
    /// labelled element in its own right, and the chart announces its own summary, so the
    /// figures are reachable without a pointer hovering over a 11pt-wide rectangle.
    private var activity: some View {
        Card("Activity", trailing: activityRange) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(insights.days, id: \.day) { day in
                        Capsule()
                            .fill(day.count > 0
                                  ? AnyShapeStyle(Palette.activity.opacity(opacity(day)))
                                  : AnyShapeStyle(.quaternary))
                            .frame(height: height(day))
                            .frame(maxWidth: 11)
                            .help("\(Figures.shortDay(day.day)) · \(day.count) dictations, \(Figures.integer(day.words)) words")
                            .accessibilityLabel(Figures.shortDay(day.day))
                            .accessibilityValue("\(day.count) dictations, \(Figures.integer(day.words)) words")
                    }
                }
                .frame(height: 56, alignment: .bottom)
                .accessibilityLabel("Dictations per day")

                HStack {
                    Text(insights.days.first.map { Figures.shortDay($0.day) } ?? "")
                    Spacer()
                    if let peak, peak.count > 0 {
                        Text("\(Figures.shortDay(peak.day)) · \(peak.count)")
                    }
                    Spacer()
                    Text(insights.days.last.map { Figures.shortDay($0.day) } ?? "")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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

    /// The six most recent dictations, in the container the platform draws for a group.
    ///
    /// It was a hand-built header bar in `controlBackgroundColor` over rows on
    /// `textBackgroundColor`, inside an 8pt rounded rectangle with its own hairline. That is
    /// three custom surfaces where the system has one, and it is the pattern the platform
    /// now asks apps to stop drawing themselves.
    private var latest: some View {
        Card("Latest") {
            VStack(spacing: 0) {
                ForEach(Array(store.descending.prefix(6).enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    LatestRow(row: row)
                }
            }
            .padding(.horizontal, -4)

            Button("Show All in History", action: showAll)
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

/// One line of the Latest list, carrying its route dot like every other place a dictation
/// appears in this window.
private struct LatestRow: View {
    let row: HistoryRow

    var body: some View {
        HStack(spacing: 10) {
            Text(Figures.clock(row.ts))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            RouteDot(route: row.route)
            Text(Figures.flatten(row.text))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            latency
        }
        .padding(.horizontal, 4)
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
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
