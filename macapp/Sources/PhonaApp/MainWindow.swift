import AppKit
import PhonaCore
import SwiftUI

/// The four things the window can show.
enum Pane: String, Hashable, CaseIterable, Identifiable {
    case home
    case history
    case dictionary
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .models: return "Models"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock"
        case .dictionary: return "book.closed"
        case .models: return "slider.horizontal.3"
        }
    }
}

/// The window's root. A sidebar and one pane, nothing that owns state of its own.
///
/// The store is passed in rather than created here, because the reload trigger is the window
/// becoming key and only `AppDelegate` can see that. A `@StateObject` here would leave the
/// window delegate with nothing to call.
struct MainWindowView: View {
    @ObservedObject var store: HistoryStore
    @State private var pane: Pane = .home

    /// Runs the existing menu-bar flag flow, alert and all, so the window has exactly one
    /// way of flagging a dictation rather than a second copy of it.
    let flag: () -> Void

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(minWidth: 690, minHeight: 620)
        }
        .navigationTitle("Phona")
        .navigationSubtitle(pane.title)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Label {
                        HStack(spacing: 6) {
                            Text(item.title)
                            Spacer(minLength: 4)
                            if let badge = badge(for: item) {
                                Text(badge)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: item.symbol)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)

            Divider()
            RouteLegend()
        }
        .navigationSplitViewColumnWidth(210)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .home:
            HomeView(store: store, showAll: { pane = .history })
        case .history:
            HistoryView(store: store, flag: flag)
        case .dictionary:
            DictionaryView(store: store)
        case .models:
            ModelsView(store: store)
        }
    }

    private func badge(for item: Pane) -> String? {
        switch item {
        case .history:
            let count = store.rows.count
            return count > 0 ? Figures.integer(count) : nil
        case .dictionary:
            let count = store.snapshot.dictionary.count
            return count > 0 ? Figures.integer(count) : nil
        default:
            return nil
        }
    }
}

/// What the dot on every dictation means, in the one place that is always on screen.
///
/// It names the dot rather than the Option keys, because the key and the dot can disagree.
/// The key chooses which correction is asked for and the dot reports what happened to the
/// text, so a right-Option dictation whose cloud reply was thrown away was corrected on this
/// Mac and still carries the blue dot: the transcript had already gone. A legend that read
/// "right ⌥ means cloud" would leave a reader thinking a green dot on that row was possible.
struct RouteLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("The dot on a dictation")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            row(route: .local, label: "stayed on this Mac")
            row(route: .cloud, label: "went to the cloud")
            Text("Left ⌥ asks for the on-device correction, right ⌥ for the cloud one. A "
                + "cloud request that was refused still went, so it keeps the blue dot.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func row(route: Route, label: String) -> some View {
        HStack(spacing: 7) {
            RouteDot(route: route)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The one design idea that appears on every dictation in the window.
///
/// Green for text that stayed on this Mac, blue for text that did not. It is drawn from
/// `HistoryRow.route`, which reads whether the transcript was handed to a cloud process
/// rather than which key was held or whose answer was used, because those two both draw a
/// green dot on a dictation the cloud has already seen.
///
/// System colours rather than the mock-up's hex, so both dots stay legible when the window
/// is in dark appearance.
struct RouteDot: View {
    let route: Route
    var diameter: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Palette.route(route))
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(route == .local ? "stayed on this Mac" : "went to the cloud")
    }
}

/// The route as a word, for places that have room for one.
///
/// A statement about the text rather than the route's own name, because "cloud" beside a
/// dictation reads as the cloud having corrected it and the dot only claims the text went
/// there. Kept short because the master row carries up to three more chips beside it.
struct RouteBadge: View {
    let route: Route

    var body: some View {
        Text(route == .local ? "on this Mac" : "left this Mac")
            .font(.system(size: 10))
            .foregroundStyle(Palette.route(route))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Palette.route(route).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// A short word for something notable about a row, in the same shape as `RouteBadge`.
struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// A titled box, which is the only container shape the mock-ups use.
struct Card<Content: View>: View {
    let title: String?
    var trailing: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil,
         trailing: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

/// Every colour the window uses, all of them semantic.
///
/// Nothing here is a hex value lifted from the mock-up HTML, because those were picked in
/// light appearance only and a route dot that vanishes in dark appearance is the one thing
/// this design cannot afford to lose.
enum Palette {
    static func route(_ route: Route) -> Color {
        route == .local ? .green : .blue
    }

    static let guarded = Color.orange
    static let flagged = Color.red
    static let slow = Color.orange
    static let activity = Color.green
}

/// Every figure the window prints, formatted once.
///
/// Shared rather than per-pane because the same number appears on Home and in History and
/// has to read identically in both, and because a duration formatted two ways is how a
/// reader concludes one of them is wrong.
enum Figures {
    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func integer(_ value: Int) -> String {
        integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func decimal(_ value: Double, places: Int = 1) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.\(places)f", value)
    }

    /// Whole hours and whole minutes, never a decimal hour. Nobody reads "6.85 h".
    static func hoursAndMinutes(fromMinutes minutes: Double) -> (hours: Int, minutes: Int) {
        guard minutes.isFinite, minutes > 0 else { return (0, 0) }
        let total = Int(minutes.rounded())
        return (total / 60, total % 60)
    }

    /// A latency, in the units a speaker would use for it. Under ten seconds is the
    /// difference between 2.1 and 3.4 seconds, over ten it never is.
    static func latency(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        return seconds < 10 ? "\(decimal(seconds)) s" : "\(Int(seconds.rounded())) s"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let secondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
    static func clockSeconds(_ date: Date) -> String { secondsFormatter.string(from: date) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func shortDay(_ date: Date) -> String { shortDayFormatter.string(from: date) }

    /// The full stamp a detail pane shows, which is a short day and a time to the second,
    /// because two dictations a minute apart are common and two in the same second are not.
    static func stamp(_ date: Date) -> String {
        "\(shortDay(date)), \(clockSeconds(date))"
    }

    /// A row's text on one line, for a list. A corrected dictation can be a multi-line list,
    /// and a newline breaks the single-line shape of a row.
    static func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// An empty state, used wherever a pane can legitimately have nothing to show.
///
/// Its own view because every pane needs one and because a zero-row history has to render as
/// a sentence rather than as a screen full of zeros, which reads as a broken app.
struct EmptyPane: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
