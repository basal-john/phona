# Settings Window Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Phona's Settings window from eight stacked `Form` sections into three tabs with an honest Save button, without changing what any control writes to `config.json`.

**Architecture:** The five settings the daemon only reads at startup move into a pure `EngineSettings` value in the `PhonaCore` target, together with the text parsing that currently sits inline in `SettingsView.save()`. `SettingsView` keeps a snapshot of that value as loaded and compares it against the live form state, which is what lets Save be disabled until a restart is actually needed. The layout change comes last, so the parsing extraction can be reviewed and rejected on its own.

**Tech Stack:** Swift 6 tools with language mode v5, SwiftUI, XCTest, macOS 14 minimum. `swift build -c release` via `macapp/build.sh`.

## Global Constraints

- Window keeps `styleMask: [.titled, .closable]`. No minimize, no zoom, no resize. This is deliberate, not an oversight.
- Window width goes from 460 to 520. The `NSWindow` `contentRect` in `main.swift` and the SwiftUI `.frame` in `SettingsView.swift` must carry the same numbers, or `NSHostingView` clips.
- The five restart-requiring settings are exactly: `mode`, `dictionary`, `use_initial_prompt`, `replacements`, `spoken_layout`.
- The app-side settings keep applying immediately through `.onChange` and `Settings.set`, with no Save involvement: `mute_others`, `show_in_dock`, and login registration via `SMAppService`.
- Save button text is exactly `Save and restart engine`.
- No `//` comments inside function bodies. `///` doc comments on declarations only. This matches the existing files.
- Commit messages are imperative sentence-case with no `feat:` or `fix:` prefix, matching this repository's history.
- No animation work. Nothing here is gesture-driven.
- The "Also copy to clipboard" control belongs to `2026-08-04-clipboard-retention-and-mode-labels-design.md` and is **not** built by this plan. The General tab below leaves room for it.
- Every control must still round-trip to the same `config.json` key with the same value type it wrote before.
- Every line number in this plan is as of commit `d242d3c`, the branch point. Tasks 2 and 3 shift them before Task 4 runs, so locate code by the symbol named in each step, for example `load()`, `save()` or `body`, and treat the line number as a hint about where it started.

---

## File Structure

- **Create** `macapp/Sources/PhonaCore/EngineSettings.swift`, holding the five restart-requiring settings as an `Equatable` value plus the pure text-to-structured parsing for the vocabulary and replacements boxes. It lives in `PhonaCore` because that target exists for logic testable without an app, a microphone or a granted permission.
- **Create** `macapp/Tests/PhonaCoreTests/EngineSettingsTests.swift`, with real unit tests for the parsing and the equality.
- **Modify** `macapp/Sources/PhonaApp/SettingsView.swift` to consume `EngineSettings`, track dirtiness, restructure into three tabs, and widen.
- **Modify** `macapp/Sources/PhonaApp/main.swift:375-377` for the window `contentRect`.

---

### Task 1: EngineSettings as a tested pure value

**Files:**
- Create: `macapp/Sources/PhonaCore/EngineSettings.swift`
- Test: `macapp/Tests/PhonaCoreTests/EngineSettingsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct EngineSettings: Equatable` with stored properties `mode: String`, `dictionary: [String]`, `biasVocabulary: Bool`, `replacements: [String: String]`, `spokenLayout: Bool`, a memberwise `public init` with that exact argument order, and four static pure functions: `words(fromText: String) -> [String]`, `text(fromWords: [String]) -> String`, `replacements(fromText: String) -> [String: String]`, `text(fromReplacements: [String: String]) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `macapp/Tests/PhonaCoreTests/EngineSettingsTests.swift`:

```swift
import XCTest
@testable import PhonaCore

final class EngineSettingsTests: XCTestCase {

    /// The Save button is driven by comparing the form against what was loaded, so a
    /// trailing newline or a stray space in the vocabulary box must not read as a change.
    /// Otherwise Save offers an engine restart for an edit the user did not make.
    func testBlankLinesAndPaddingAreNotAChange() {
        let clean = EngineSettings.words(fromText: "Phona\nJira")
        let messy = EngineSettings.words(fromText: "  Phona  \n\n Jira \n")
        XCTAssertEqual(clean, messy)
        XCTAssertEqual(clean, ["Phona", "Jira"])
    }

    func testWordOrderIsPreserved() {
        XCTAssertEqual(EngineSettings.words(fromText: "beta\nalpha"), ["beta", "alpha"])
    }

    func testWordsRoundTripThroughText() {
        let words = ["Phona", "Jira", "Whisper"]
        XCTAssertEqual(EngineSettings.words(fromText: EngineSettings.text(fromWords: words)), words)
    }

    func testReplacementsParseOnPaddedPairs() {
        let pairs = EngineSettings.replacements(fromText: "con job = cron job\n free tire = free tier ")
        XCTAssertEqual(pairs, ["con job": "cron job", "free tire": "free tier"])
    }

    /// A line the user is halfway through typing has no separator yet, and must be skipped
    /// rather than stored under an empty key.
    func testLineWithoutASeparatorIsIgnored() {
        XCTAssertEqual(EngineSettings.replacements(fromText: "con job"), [:])
    }

    func testEmptyKeyIsDropped() {
        XCTAssertEqual(EngineSettings.replacements(fromText: " = cron job"), [:])
    }

    /// Only the first separator splits, so a replacement whose value contains an equals
    /// sign survives intact.
    func testOnlyTheFirstSeparatorSplits() {
        XCTAssertEqual(EngineSettings.replacements(fromText: "arrow = a = b"), ["arrow": "a = b"])
    }

    func testReplacementsRoundTripThroughText() {
        let pairs = ["con job": "cron job", "free tire": "free tier"]
        let text = EngineSettings.text(fromReplacements: pairs)
        XCTAssertEqual(EngineSettings.replacements(fromText: text), pairs)
    }

    func testReplacementTextIsSortedSoTheBoxDoesNotReorderItself() {
        let text = EngineSettings.text(fromReplacements: ["zulu": "z", "alpha": "a"])
        XCTAssertEqual(text, "alpha = a\nzulu = z")
    }

    func testIdenticalSettingsAreEqual() {
        XCTAssertEqual(Self.sample(), Self.sample())
    }

    func testEachFieldBreaksEquality() {
        var mode = Self.sample()
        mode.mode = "polish"
        XCTAssertNotEqual(Self.sample(), mode)

        var dictionary = Self.sample()
        dictionary.dictionary = ["Phona", "Extra"]
        XCTAssertNotEqual(Self.sample(), dictionary)

        var bias = Self.sample()
        bias.biasVocabulary = true
        XCTAssertNotEqual(Self.sample(), bias)

        var replacements = Self.sample()
        replacements.replacements = ["a": "b"]
        XCTAssertNotEqual(Self.sample(), replacements)

        var layout = Self.sample()
        layout.spokenLayout = false
        XCTAssertNotEqual(Self.sample(), layout)
    }

    private static func sample() -> EngineSettings {
        EngineSettings(mode: "grammar",
                       dictionary: ["Phona"],
                       biasVocabulary: false,
                       replacements: ["con job": "cron job"],
                       spokenLayout: true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macapp && swift test --filter EngineSettingsTests`
Expected: FAIL to compile, with `cannot find 'EngineSettings' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macapp/Sources/PhonaCore/EngineSettings.swift`:

```swift
import Foundation

/// The settings the daemon reads only once, at startup.
///
/// `load_config()` runs a single time in the daemon's `main` and is stored on the engine,
/// with no reload path and no file watcher, so changing any of these takes effect only after
/// a restart. That is what separates them from the app-side settings, which apply the moment
/// they are toggled. Holding them in one comparable value is what lets the Settings window
/// offer a restart only when one is genuinely needed.
public struct EngineSettings: Equatable {
    public var mode: String
    public var dictionary: [String]
    public var biasVocabulary: Bool
    public var replacements: [String: String]
    public var spokenLayout: Bool

    public init(mode: String,
                dictionary: [String],
                biasVocabulary: Bool,
                replacements: [String: String],
                spokenLayout: Bool) {
        self.mode = mode
        self.dictionary = dictionary
        self.biasVocabulary = biasVocabulary
        self.replacements = replacements
        self.spokenLayout = spokenLayout
    }

    /// One word per line, trimmed, with blank lines dropped.
    public static func words(fromText text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func text(fromWords words: [String]) -> String {
        words.joined(separator: "\n")
    }

    /// One `wrong = right` pair per line. A line with no separator is skipped rather than
    /// stored, because it is what a half-typed line looks like. Only the first separator
    /// splits, so an equals sign inside the replacement value survives.
    public static func replacements(fromText text: String) -> [String: String] {
        var pairs: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { pairs[key] = value }
        }
        return pairs
    }

    /// Sorted, so reopening the window does not reorder the user's own list under them.
    public static func text(fromReplacements pairs: [String: String]) -> String {
        pairs.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macapp && swift test --filter EngineSettingsTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Confirm nothing else broke**

Run: `cd macapp && swift test`
Expected: PASS, the `UpdateCheckTests` cases plus the new ones.

- [ ] **Step 6: Commit**

```bash
git add macapp/Sources/PhonaCore/EngineSettings.swift macapp/Tests/PhonaCoreTests/EngineSettingsTests.swift
git commit -m "Give the restart-only settings a value that can be compared"
```

---

### Task 2: SettingsView reads and writes through EngineSettings

Behaviour must not change in this task. Same keys, same values, same Save-restarts-daemon flow. This is the extraction, kept apart from the layout work so it can be reviewed on its own.

**Files:**
- Modify: `macapp/Sources/PhonaApp/SettingsView.swift:121-161`

**Interfaces:**
- Consumes: `EngineSettings` and its four static parsing functions from Task 1.
- Produces: a `private var current: EngineSettings` computed property on `SettingsView`, and a `@State private var loaded: EngineSettings?` holding the snapshot as read from disk. Task 3 relies on both.

- [ ] **Step 1: Import the core module and add the snapshot state**

At the top of `SettingsView.swift`, alongside `import ServiceManagement` and `import SwiftUI`, add:

```swift
import PhonaCore
```

Add to the `@State` block, after `status`:

```swift
@State private var loaded: EngineSettings?
```

- [ ] **Step 2: Add the computed current value**

Insert above `private func load()`:

```swift
/// The restart-requiring settings as the form currently shows them.
private var current: EngineSettings {
    EngineSettings(mode: mode.rawValue,
                   dictionary: EngineSettings.words(fromText: dictionary),
                   biasVocabulary: biasVocabulary,
                   replacements: EngineSettings.replacements(fromText: replacements),
                   spokenLayout: spokenLayout)
}
```

- [ ] **Step 3: Rewrite load() to build the snapshot**

Replace the body of `load()` (currently `SettingsView.swift:121-134`) with:

```swift
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
```

`loaded = current` comes last on purpose, so the snapshot reflects the fields after every one has been assigned.

- [ ] **Step 4: Rewrite the persisting half of save()**

In `save()`, replace the block that writes `dictionary` and builds `pairs` (currently `SettingsView.swift:148-161`) with:

```swift
obj["dictionary"] = EngineSettings.words(fromText: dictionary)
obj["replacements"] = EngineSettings.replacements(fromText: replacements)
```

Leave `obj["mode"]`, `obj["use_initial_prompt"]`, `obj["output_action"]` and `obj["spoken_layout"]` exactly as they are. Leave the `JSONSerialization` write, the error handling and the daemon restart untouched.

- [ ] **Step 5: Build**

Run: `cd macapp && swift build -c release`
Expected: builds with no errors and no new warnings.

- [ ] **Step 6: Verify the round trip by hand**

Back up the real config first, since this writes to it:

```bash
cp ~/.local/share/phona/config.json /tmp/phona-config-before.json
```

Open Settings from the menu bar, press Save without editing anything, then compare:

```bash
diff <(python3 -m json.tool /tmp/phona-config-before.json) \
     <(python3 -m json.tool ~/.local/share/phona/config.json)
```

Expected: no differences. A Save with no edits must be a no-op on the file, which proves the parsing extraction is faithful in both directions.

- [ ] **Step 7: Commit**

```bash
git add macapp/Sources/PhonaApp/SettingsView.swift
git commit -m "Read and write the restart-only settings through one value"
```

---

### Task 3: Save states its cost and stays disabled until it has one

**Files:**
- Modify: `macapp/Sources/PhonaApp/SettingsView.swift:100-106` and the end of `save()`

**Interfaces:**
- Consumes: `current` and `loaded` from Task 2.
- Produces: a `private var needsRestart: Bool` computed property, relied on by the footer in Task 4.

- [ ] **Step 1: Add the dirty check**

Insert next to `current`:

```swift
/// True when a field the daemon only reads at startup differs from what was loaded.
/// The app-side toggles are deliberately excluded, because they already applied.
private var needsRestart: Bool {
    guard let loaded else { return false }
    return current != loaded
}
```

Returning `false` when `loaded` is `nil` is correct: the snapshot is only absent before `load()` has run or when the config file could not be read, and offering a restart in either case would write a file built from defaults the user never chose.

- [ ] **Step 2: Rewrite the Save row**

Replace the final `Section` of the `Form` (currently `SettingsView.swift:100-106`) with:

```swift
Section {
    HStack {
        Text(status).font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button("Save and restart engine") { save() }
            .keyboardShortcut(.defaultAction)
            .disabled(!needsRestart)
    }
}
```

- [ ] **Step 3: Re-snapshot after a successful save**

In `save()`, the success path currently sets `status = "Saved. Restarting the engine…"` before the async restart. Immediately after that line, add:

```swift
loaded = current
```

Without this the button stays enabled after saving, because the snapshot would still hold the pre-save values.

- [ ] **Step 4: Build**

Run: `cd macapp && swift build -c release`
Expected: builds clean.

- [ ] **Step 5: Verify the four behaviours by hand**

Rebuild and reinstall so the running app carries the change:

```bash
cd macapp && ./build.sh && cd .. && ./update.sh
```

Then check, in order:

1. Open Settings. Save is **disabled**.
2. Type a trailing newline into the Vocabulary box. Save stays **disabled**, because blank lines are not a change.
3. Change Correction mode. Save becomes **enabled** and reads `Save and restart engine`.
4. Toggle `Mute other audio`. Save stays **disabled**, and the setting still lands in `config.json` with the window open:

```bash
python3 -c "import json;print(json.load(open('$HOME/.local/share/phona/config.json'))['mute_others'])"
```

5. Press Save. The engine restarts, status reaches `Saved.`, and Save returns to **disabled**.

- [ ] **Step 6: Commit**

```bash
git add macapp/Sources/PhonaApp/SettingsView.swift
git commit -m "Say what Save costs, and only offer it when it buys something"
```

---

### Task 4: Three tabs and a wider window

**Files:**
- Modify: `macapp/Sources/PhonaApp/SettingsView.swift:17-119`
- Modify: `macapp/Sources/PhonaApp/main.swift:375-377`

**Interfaces:**
- Consumes: `needsRestart` and `save()` from Task 3, `modeExplanation` unchanged.
- Produces: nothing later tasks depend on. This is the last task.

- [ ] **Step 1: Split the body into three tab views plus a shared footer**

Replace `body` (currently `SettingsView.swift:17-111`) with:

```swift
var body: some View {
    VStack(spacing: 0) {
        TabView {
            general.tabItem { Text("General") }
            dictation.tabItem { Text("Dictation") }
            words.tabItem { Text("Words") }
        }
        Divider()
        HStack {
            Text(status).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Save and restart engine") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!needsRestart)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    .frame(width: 520, height: 560)
    .onAppear(perform: load)
}
```

The footer sits outside `TabView` because the fields it commits are spread across all three tabs, so repeating it per tab would imply three independent Saves. The `Section` added in Task 3 Step 2 is replaced by this footer, so the Save row must not appear twice.

- [ ] **Step 2: Add the General tab**

Insert after `body`:

```swift
private var general: some View {
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
    }
    .formStyle(.grouped)
}
```

- [ ] **Step 3: Add the Dictation tab**

```swift
private var dictation: some View {
    Form {
        Section {
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
            Toggle("Act on spoken layout commands", isOn: $spokenLayout)
            Text("Say \"new paragraph\", \"new line\" or \"bullet point\" as a sentence "
                 + "of its own and it becomes a real break. Off means those words are "
                 + "typed out.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    .formStyle(.grouped)
}
```

- [ ] **Step 4: Add the Words tab**

The two editors gain height, since this tab exists to give them room. Vocabulary goes 76 to 120, Replacements 62 to 120.

```swift
private var words: some View {
    Form {
        Section("Vocabulary") {
            Text("Words the transcriber tends to mangle. One per line.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $dictionary)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
            Toggle("Bias the transcriber toward these words", isOn: $biasVocabulary)
            Text("Improves rare names, at the cost of occasionally inventing words in silence.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Section("Replacements") {
            Text("Applied literally, before the layout pass. One per line, as wrong = right.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $replacements)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
        }
    }
    .formStyle(.grouped)
}
```

- [ ] **Step 5: Match the window to the view**

In `main.swift`, change the `contentRect` at line 376 from `width: 460, height: 580` to:

```swift
contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
```

Leave `styleMask: [.titled, .closable]` alone. These numbers must equal the `.frame(width: 520, height: 560)` from Step 1.

- [ ] **Step 6: Build and check every section survived**

Run: `cd macapp && swift build -c release && ./build.sh && cd .. && ./update.sh`

Then open Settings and confirm all eight original sections are present and none was orphaned:

- General: Correction with its explanation, When done, Show in Dock, Open at login
- Dictation: Mute other audio, Act on spoken layout commands
- Words: Vocabulary with its bias toggle, Replacements

Confirm also that the window still has only a close button, and that dragging its edge does not resize it.

- [ ] **Step 7: Re-run the full suite**

Run: `cd macapp && swift test && cd .. && ~/.local/share/phona/venv/bin/python -m pytest tests/test_logic.py tests/test_packaging.py -q`
Expected: Swift tests pass. Python stays at 140 passed, since nothing in this plan touches the engine.

- [ ] **Step 8: Commit**

```bash
git add macapp/Sources/PhonaApp/SettingsView.swift macapp/Sources/PhonaApp/main.swift
git commit -m "Give the settings window three tabs instead of one long scroll"
```

---

## Still open after this plan

The spec's visual craft pass is not covered here and cannot be, because it needs the rendered window. Specifically unverified until someone looks at it: whether 520 by 560 is the right size, whether the footer padding of 20 by 12 sits right against the grouped form's own insets, and whether 120 points is enough for the two editors. Adjusting those numbers is a follow-up, not part of any task above.

`Text` labels are used for the tab items rather than `Label` with an SF Symbol, because picking three icons is a visual decision that belongs with that same pass.
