# Handoff, 2026-08-02 late

## What happened

Built `vfix`, a local hold-to-talk dictation app with a grammar pass, from the initial
question about huggingface/speech-to-speech. Ended as a native Swift menu bar app plus a
Python model daemon, in a private GitHub repo with a released DMG.

## Where things are

| What | Where |
| --- | --- |
| Repo | github.com/basal-john/vfix, **private**, release v1.0.0 with the DMG |
| Local repo | `~/Developer/vfix` |
| Installed app | `/Applications/vfix.app`, running |
| Runtime and engine | `~/.local/share/vfix` |
| Hammerspoon fallback | `~/.hammerspoon/init.lua`, stands down while the app runs |

## Waiting on the user

1. **Grant Accessibility and Microphone.** The setup window is open. macOS does not allow
   an app to grant itself these, so this is the one blocker. Nothing else is pending.
2. **Repo is private.** It was deliberately not made public overnight, since publishing is
   outward-facing and hard to reverse. One command flips it:
   `gh repo edit basal-john/vfix --visibility public`

## Verified

- Grammar suite 23/29 exact, unchanged before and after the app rewrite. Most differences
  are acceptable paraphrase. Real remaining issue: `rollback` used as a verb.
- 12/12 synthesized dictations transcribed and corrected end to end through the daemon.
- Recording lifecycle: 5 rapid Option taps leave zero orphaned processes and no stale state.
- PID-reuse guard: a decoy process with a matching pid file was not killed.
- DMG mounts, app inside is correctly signed, arm64, right bundle id.
- HUD and onboarding rendered offscreen and inspected, via `vfix --render <dir>`.

## Not verified

- **The live dictation path in the app.** It needs the two permissions, so it could not be
  exercised. The daemon side of it is verified, and the Hammerspoon build ran the same
  pipeline successfully earlier tonight, but the Swift capture and paste path has never
  run for real.
- **The Settings window visually.** `ImageRenderer` cannot draw `Form` or `TextEditor`, and
  the Mac was locked, so it was verified by logic (config round trip, replacements applied)
  rather than by eye.

## If something is wrong tomorrow

- Nothing on Option hold: Accessibility not granted, check the menu bar Setup item.
- Logs: `~/.local/share/vfix/app.log`, `vfixd.log`, `history.jsonl`.
- Worst case the app misbehaves: quit it and Hammerspoon takes over automatically within
  five seconds, using the same engine.
