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

    /// Command-1 through Command-4, in sidebar order.
    ///
    /// The platform expects a keyboard route to every view a window can show, and these are
    /// the shortcuts every other Mac app with a four-item sidebar uses. They are declared
    /// here rather than in the menu builder so the sidebar order and the shortcut order
    /// cannot drift apart.
    var shortcut: Character {
        switch self {
        case .home: return "1"
        case .history: return "2"
        case .dictionary: return "3"
        case .models: return "4"
        }
    }
}

/// What the window is showing, held outside the view.
///
/// The pane and the history filter both need to be reachable from the menu bar, because a
/// toolbar can be hidden or customised and so may not be the only route to a command. A
/// `@State` inside `MainWindowView` is reachable from nothing, which is why this exists.
final class WindowModel: ObservableObject {
    @Published var pane: Pane = .home
    @Published var filter: HistoryFilter = .all
    @Published var legendShown = false
}

/// The window's root. A sidebar and one pane, nothing that owns state of its own.
///
/// The store and the selection are both passed in rather than created here. The reload
/// trigger is the window becoming key and only `AppDelegate` can see that, and the menu bar
/// needs to move the selection, which it can only do through a value it also holds.
struct MainWindowView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var model: WindowModel

    /// Runs the existing menu-bar flag flow, alert and all, so the window has exactly one
    /// way of flagging a dictation rather than a second copy of it.
    let flag: () -> Void

    init(store: HistoryStore, model: WindowModel = WindowModel(), flag: @escaping () -> Void) {
        self.store = store
        self.model = model
        self.flag = flag
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                /// Low enough to put the window on half a laptop screen. Nothing clips at
                /// this size, because every pane owns its own scrolling container, so the
                /// floor only has to keep the content legible rather than whole.
                .frame(minWidth: 520, minHeight: 320)
        }
        .navigationTitle("Phona")
        .navigationSubtitle(model.pane.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.legendShown.toggle()
                } label: {
                    Label("What the dots mean", systemImage: "info.circle")
                }
                .help("What the dot on a dictation means")
                .popover(isPresented: $model.legendShown, arrowEdge: .bottom) {
                    RouteLegend().frame(width: 300)
                }
            }
        }
    }

    /// The sidebar, and only the sidebar.
    ///
    /// The route legend used to be pinned under this list. It is the one thing in the window
    /// that explains the app's privacy claim, and the bottom edge of a window is the part
    /// people drag off the screen, so it now lives behind a toolbar button and in the Help
    /// menu instead, where it is reachable from every pane and cannot be hidden by a drag.
    private var sidebar: some View {
        List(selection: $model.pane) {
            ForEach(Pane.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .home:
            HomeView(store: store, showAll: { model.pane = .history })
        case .history:
            HistoryView(store: store, filter: $model.filter, flag: flag)
        case .dictionary:
            DictionaryView(store: store)
        case .models:
            ModelsView(store: store)
        }
    }

    /// Zero rather than nil for an empty count, because `badge` hides a zero on its own and
    /// a badge that appears and disappears as rows arrive is noisier than one that does not.
    private func badge(for item: Pane) -> Int {
        switch item {
        case .history: return store.rows.count
        case .dictionary: return store.snapshot.dictionary.count
        default: return 0
        }
    }
}

/// What the dot on every dictation means, in one place the whole window can reach.
///
/// It names the dot rather than the Option keys, because the key and the dot can disagree.
/// The key chooses which correction is asked for and the dot reports what happened to the
/// text, so a right-Option dictation whose cloud reply was thrown away was corrected on this
/// Mac and still carries the blue mark: the transcript had already gone. A legend that read
/// "right ⌥ means cloud" would leave a reader thinking a green mark on that row was possible.
struct RouteLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The mark on a dictation")
                .font(.headline)
            row(route: .local, label: "Stayed on this Mac")
            row(route: .cloud, label: "Went to the cloud")
            Text("Left ⌥ asks for the on-device correction, right ⌥ for the cloud one. A "
                + "cloud request that was refused still went, so it keeps the blue mark.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func row(route: Route, label: String) -> some View {
        HStack(spacing: 8) {
            RouteDot(route: route)
            Text(label)
                .font(.callout)
        }
    }
}

/// The one design idea that appears on every dictation in the window.
///
/// A filled dot for text that stayed on this Mac, an arrow for text that did not, green and
/// blue behind them. The two shapes carry the whole distinction on their own, because a
/// reader who cannot separate green from blue is a reader this mark has to work for, and on
/// the Home pane it is the only route signal on the row.
///
/// It is drawn from `HistoryRow.route`, which reads whether the transcript was handed to a
/// cloud process rather than which key was held or whose answer was used, because those two
/// both draw a green mark on a dictation the cloud has already seen.
///
/// A symbol at a text style rather than a `Circle` at a point size, so it sits on the
/// baseline of whatever it is beside and grows with it.
struct RouteDot: View {
    let route: Route
    var font: Font = .caption

    var body: some View {
        Image(systemName: route == .local ? "circle.fill" : "arrow.up.circle.fill")
            .font(font)
            .foregroundStyle(Palette.route(route))
            .accessibilityLabel(route == .local ? "stayed on this Mac" : "went to the cloud")
    }
}

/// The route as a word, for places that have room for one.
///
/// A statement about the text rather than the route's own name, because "cloud" beside a
/// dictation reads as the cloud having corrected it and the mark only claims the text went
/// there. Kept short because the master row carries up to three more chips beside it.
struct RouteBadge: View {
    let route: Route

    var body: some View {
        Chip(text: route == .local ? "on this Mac" : "left this Mac",
             tint: Palette.route(route))
    }
}

/// A short word for something notable about a row.
///
/// A capsule rather than a 3pt rounded rectangle, because the platform rounded every small
/// control when the shape of the hardware started informing the shape of the interface, and
/// a chip beside a capsule button with squarer corners than it reads as a mistake.
struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A titled container, which is the only grouping shape the window uses.
///
/// A `GroupBox` rather than a hand-drawn fill and hairline. The old version painted
/// `controlBackgroundColor` inside an 8pt rounded rectangle with a quaternary stroke, which
/// was a passable imitation of the system's grouped container on the OS it was written for
/// and is now the wrong radius, the wrong fill and one border too many. `GroupBox` is the
/// component the platform styles, so the corner radius, the material and the way it behaves
/// under Reduce Transparency and Increase Contrast all arrive without being restated here.
///
/// The title is not upper-cased. Lists, tables and forms across the system now render
/// section headers in title-style capitalisation, and a pane of small capitals beside them
/// reads as a different app.
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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, title == nil && trailing == nil ? 0 : 4)
        } label: {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title {
                        Text(title)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Every colour the window uses, all of them semantic.
///
/// Nothing here is a hex value lifted from a mock-up, because those were picked in light
/// appearance only and a route mark that vanishes in dark appearance is the one thing this
/// design cannot afford to lose. The system colours also carry an increased-contrast
/// variant, which a hex value does not.
enum Palette {
    static func route(_ route: Route) -> Color {
        route == .local ? .green : .blue
    }

    static let guarded = Color.orange
    static let flagged = Color.red
    static let slow = Color.orange
    static let activity = Color.green
}

/// The two display sizes the window uses, which are the only sizes here that are not a
/// system text style.
///
/// macOS has no Dynamic Type, so a fixed size for a headline figure is legitimate. It is
/// named rather than inlined because the same figure appears at two scales and the pair has
/// to stay in proportion. Everything else in the window is a text style, which is what keeps
/// it in step with the standard controls beside it.
enum Display {
    static let hero = Font.system(size: 40, weight: .semibold)
    static let tile = Font.system(size: 26, weight: .semibold)
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
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private static let secondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmmss")
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
/// `ContentUnavailableView` rather than a stack of a symbol and two labels. It is the
/// component the system uses for this, so the symbol size, the spacing, the text styles and
/// the way it centres itself in a resizing pane are all the platform's rather than this
/// app's approximation of them, and the symbol is correctly hidden from VoiceOver instead of
/// being read out as decoration.
struct EmptyPane: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
    }
}
