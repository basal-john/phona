# Give the Settings window a structure

**Status:** approved, ready to plan
**Date:** 2026-08-04

## Outcome

The Settings window gets three tabs instead of eight stacked sections, a width that fits its
widest content, and an honest Save button. It keeps a close button only and stays fixed size,
which is the macOS convention.

## Why

`SettingsView.body` puts eight `Section`s in one scrolling `Form` at a fixed 460 points wide
(`SettingsView.swift:18-109`, `main.swift:375-377`). Nothing groups them, so the window does
not say what relates to what, and the two `TextEditor`s are only 76 and 62 points tall.

Apple's Simplicity principle is explicit that putting everything in one place looks minimal
without being simple, and that the common path comes first with advanced options one level
deeper. A tab toolbar is how Safari, Mail and Messages settings solve exactly this.

### On window chrome

The window is `styleMask: [.titled, .closable]`, so it has no minimize, no zoom and no
resize. That was raised as a defect and is being kept deliberately. macOS settings windows
conventionally carry a close button and nothing else, because a settings window is a
transient inspector rather than a document, which makes minimizing it to the Dock or zooming
it to fullscreen meaningless states. System Settings resizes because it is a full app with a
sidebar, not a preferences sheet.

The cramped feeling is therefore addressed with structure, not chrome.

## Design

### Three tabs

| Tab | Contains |
| --- | --- |
| **General** | Correction mode and its explanation. When done (insert at cursor / copy to clipboard, plus "Also copy to clipboard"). Show Phona in the Dock. Open Phona at login. |
| **Dictation** | Mute other audio. Act on spoken layout commands. |
| **Words** | Vocabulary and its bias toggle. Replacements. |

Words is its own tab because the two monospace editors are the only controls that genuinely
want room. General leads because correction mode and output destination are what people
change.

### Width

460 to 520 points, so the monospace editors get a usable line length. Still fixed.

### The Save button

The window currently mixes two interaction models with nothing on screen to distinguish
them. `Mute other audio`, `Show Phona in the Dock` and `Open Phona at login` apply
immediately through `.onChange` and `Settings.set`. Everything else does nothing until Save
is pressed. A user can toggle spoken layout, close the window, and silently lose it.

Apple's convention is that settings apply immediately with no Save button at all. Phona has
one for a real reason: `save()` restarts the daemon, because the prompt prefix is prefilled
per mode, and restarting on every keystroke in the Vocabulary field would be unusable.

The restart is genuinely unavoidable, not a leftover. `load_config()` is called once in
`main` (`phonad.py:1065`) and stored on the engine (`phonad.py:549`), with no reload path and
no file watcher. So every daemon-side setting takes effect only on restart, which is what
makes the five fields listed below different in kind from the four app-side toggles.

So Save stays, and stops hiding its cost:

- Relabel it **"Save and restart engine"**, so the price is stated rather than discovered.
- Enable it only when a field that needs the restart has actually changed. Those are
  correction mode, vocabulary, the bias toggle, replacements, and spoken layout.
- Leave the app-side settings applying instantly, as they already do.

The button lives in the window footer, shared across all three tabs, because the settings it
commits are spread across them.

## Verification

Manual, since there is no test seam for a SwiftUI view in this project and
`UpdateCheckTests.swift` is the only Swift test.

1. Each tab renders its own sections and nothing is orphaned. All eight original sections are
   accounted for across the three tabs.
2. Every control still round-trips to `config.json` with the same key and value it wrote
   before.
3. Save is disabled on open, enables when a restart-requiring field changes, and stays
   disabled when only an app-side toggle is touched.
4. Save still restarts the daemon and the change takes effect.
5. The app-side toggles still apply with the window open, without Save.
6. The window still has a close button only, and cannot be resized.

## Open

The structure above is decided from the code, which is the right basis for information
architecture. The visual craft pass, meaning spacing, type hierarchy, and whether 520 is
actually the right width, needs the rendered window. It has not been reviewed visually yet.

## Out of scope

- Minimize, zoom and resize, per the decision above.
- Any animation work. Nothing here is gesture-driven, so motion would be decoration.
- The clipboard retention feature and the mode label fix, specified in
  `2026-08-04-clipboard-retention-and-mode-labels-design.md`. The "Also copy to clipboard"
  control appears in the General tab above so the tab contents are complete, but it is built
  by that other piece of work.
