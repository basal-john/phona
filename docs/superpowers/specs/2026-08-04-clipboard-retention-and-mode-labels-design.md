# Keep dictations on the clipboard, and stop the mode labels lying

**Status:** approved, ready to plan
**Date:** 2026-08-04

## Outcome

Two changes. A dictation can be inserted at the cursor *and* left on the clipboard, so it
reaches an iPhone through Universal Clipboard. And the correction-mode descriptions stop
implying that only Polish removes filler words, which is false.

## Why

### Clipboard retention

Dictating on the Mac and pasting on the iPhone already works today, and nothing in the UI
says so. `main.swift:464-485` builds a **Recent** section in the menu bar listing recent
dictations, and each item's action is `copyEntry`, which puts that dictation on the
clipboard. Universal Clipboard carries it from there.

What is missing is the zero-friction path: having every dictation land on the clipboard
without a second action.

### Mode labels

`SettingsView.modeExplanation:113-119` and the README table at lines 108-110 describe Polish
as the mode that "also removes filler words". `SYSTEM_PROMPT` already contains:

```
- Remove pure fillers such as um, uh, er and hmm in every mode. Nobody wants them typed.
```

So Grammar removes them too. Verified: `tests/run_model_tests.py` was run against a live
daemon in Grammar mode on 2026-08-04 and its filler case, which asserts the output contains
no `um` or `uh`, passed as part of 29 exact / 0 failed.

The descriptions also omit that Transcribe only skips the spoken-layout pass, so
"new paragraph" and "bullet point" stay as literal words. That gate is the same early return
in `postprocess` that skips correction (`phonad.py:867-868`).

## Design: an orthogonal flag, not a third mode

`output_action` answers *where the text goes*. The new setting answers *whether the
clipboard keeps it*. These are independent, so a boolean models them honestly.

| `output_action` | `keep_on_clipboard` | Result |
| --- | --- | --- |
| `insert` | `false` | Current behaviour. Inserted at the cursor, previous clipboard restored. |
| `insert` | `true` | Inserted at the cursor, and the dictation stays on the clipboard. |
| `clipboard` | either | Dictation on the clipboard, nothing inserted. Flag has no effect. |

A third `output_action` value was rejected. `output_action` is a string in `config.json` but
a `Bool` in two places (`SettingsView.swift:130` and `146`, `Paster.swift:141`), so a
tri-state would need both converted to an enum. An unknown key is ignored by older builds,
which makes the boolean a no-migration change.

Key name is `keep_on_clipboard`, matching the existing `spoken_layout`, `show_in_dock` and
`use_initial_prompt` snake_case. Default `false`.

## Components

**`Paster.swift`** gains a `Settings.keepOnClipboard` reader beside `insertAtCursor`,
defaulting to `false`.

**`main.swift:254`** will pass the existing `restore:` parameter:

```swift
switch Paster.paste(result.text, restore: !Settings.keepOnClipboard) {
```

`Paster.paste(_ text:, restore: Bool = true)` already carries this knob, so no change to
`Paster.paste` itself is needed for the feature. Insert mode already routes through the
clipboard: it copies, sends Cmd+V, then restores the previous contents after 0.3s
(`Paster.swift:75-82`). Retention is that restore not happening.

**Menu bar** gains a checkable "Also copy to clipboard" item, following the `Correction mode`
submenu pattern at `main.swift:491-502`: state read from config on every `menuNeedsUpdate`,
which already rebuilds the whole menu on open. Unlike `Mode.apply()`, this must **not**
restart the daemon. Output settings are app-side, as the `Settings` enum states: "App-side
settings that the daemon does not need to know about."

**Settings window** gains the matching checkbox under the "When done" picker, so the setting
is reachable from both places.

**Shared config writer.** This becomes the third read-merge-write of `config.json`
(`SettingsView.save`, `Mode.apply`, and now the menu toggle). Extract one small helper rather
than duplicating the merge block again.

## A bug this exposes

`Paster.swift:60` gates the clipboard-clobbered warning on `restore`:

```swift
if restore, previous == nil, hadItems {
    warning = "Your clipboard held an image or file. It has been replaced and cannot be restored."
}
```

With `keep_on_clipboard` on, `restore` is `false`, an image or file on the clipboard is
destroyed, and no warning fires. The message is true either way, so the `restore` condition
should be dropped. The new setting is what makes this path reachable, so it is fixed here
rather than deferred.

## Decisions taken

- In `clipboard` output mode the menu item shows **checked and disabled**, because
  clipboard-only inherently keeps the text. Showing it as available would imply a choice that
  does not exist. Hiding it would make the setting appear to vanish.
- Naming as above.

## New label text

`SettingsView.modeExplanation` and the README table at 108-110:

- **Grammar**: "Fixes grammar, agreement, tense and punctuation, and removes um and uh.
  Keeps your wording."
- **Polish**: "Grammar, plus removes you know and I mean, and splits run-on sentences."
- **Transcribe only**: "No correction. Inserts exactly what was heard, and spoken layout
  commands stay as words."

The README also gains a line documenting the Recent-menu copy path, since not knowing it
existed is what prompted this work.

## Verification

There is no unit-test seam on the Swift side. `Paths.config` is a static path with no
injection point, and `UpdateCheckTests.swift` is the only Swift test because it is pure
logic. Adding a config-path seam so `Settings` becomes testable is a real improvement and is
out of scope here.

So verification is manual, four cases:

1. `insert` with the flag off: text inserted, previous clipboard restored.
2. `insert` with the flag on: text inserted, dictation still on the clipboard afterwards.
3. `clipboard` output mode: unchanged, nothing inserted.
4. Nothing editable focused: still reports `leftOnClipboard` and the HUD still shows the
   clipboard state.

Plus one case for the warning fix: an image on the clipboard, flag on, expect the
notification.

The Python suite is untouched by this change and should stay at its current pass count.

## Out of scope

- Any change to `output_action` itself.
- A hotkey for the existing copy-from-history action.
- The Settings window restructure, which is specified separately in
  `2026-08-04-settings-window-design.md`.
- A test seam for `Settings`.
