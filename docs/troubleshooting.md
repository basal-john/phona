# Troubleshooting

Every symptom below has a cause worth knowing. Logs first, if you are in a hurry:
`~/.local/share/phona/app.log` for the app, `phonad.log` for the engine, and `history.jsonl`
for every dictation with what was heard next to what was corrected.

## Nothing happens when I tap Option

Only the left Option key starts a dictation. If it is the left one, check Accessibility is
granted, in the menu bar under Setup and permissions. A press held longer than 500 ms is
treated as a rest on the key rather than a tap, so tap it rather than leaning on it.

## The Option key stopped working after a rebuild

It should not any more, but this is worth knowing. An ad-hoc signature's designated
requirement is the code hash itself, so macOS binds a permission grant to one exact build and
every rebuild silently orphans it. The permission keeps showing as enabled in System Settings
while the app is denied, and nothing logs a reason. `build.sh` pins the requirement to the
bundle identifier instead, which keeps grants valid across rebuilds. If a grant ever does go
stale, clear it and grant again:

```bash
tccutil reset Accessibility com.basalona.phona
tccutil reset Microphone com.basalona.phona
```

## The waveform stays flat

Wrong input device, or Microphone is not granted. Try **Warm microphone** from the menu.

## The first dictation after a reboot comes back empty

A cold input device takes about four seconds to start producing audio. The app warms it at
launch, so this should not happen, but **Warm microphone** forces it.

## Phona says the microphone delivered no audio

The input device produced not one buffer for the entire recording. That is the capture layer,
not Phona, and not you being quiet. Check System Settings, Sound, Input and watch the level
meter while you speak. If it is dead there too:

```bash
sudo killall coreaudiod
```

All audio cuts for about a second and launchd restarts it. A wedged Core Audio enumerates
every device as healthy and hands out silence, so nothing else gives it away.

## It pasted into the wrong place

Phona pastes into whatever had focus when you released Option.

## Nothing appeared, and the menu bar says it is on the clipboard

There was nowhere for the text to go, so it was kept rather than inserted. Press Cmd+V where
you want it. The capsule shows a clipboard glyph instead of a checkmark in that case, and the
cue is the quiet one rather than the completion chime. Why Phona cannot simply check that the
paste landed is in [decisions.md](decisions.md#the-clipboard).

## My image did not come back after a dictation

Check **When done** in Settings. **Insert and copy** never restores your clipboard, by
definition: it is insert without the final restore, which is exactly what leaves the dictation
there for Universal Clipboard to carry to another device. An image on the clipboard is
therefore gone after a dictation on that setting, and always was. Choose **Insert at cursor**
to keep what you had copied.

## My output stayed muted

Phona mutes the output device while it records and restores it when you let go, and puts it
back at the next launch if it was killed in between. To see which control your device offers
and watch a mute and a restore go through:

```bash
/Applications/Phona.app/Contents/MacOS/PhonaApp --check-mute
```

## The capsule shows scissors

The transcriber started looping and the repeated tail was cut off, so what landed is real but
may be shorter than what you said. One dictation came back as 29 real words followed by
"balloon" 219 times. The whole transcript, tail included, is in
`~/.local/share/phona/app.log`. The menu bar says how many words were cut.

## The capsule shows a warning triangle and the menu bar keeps a mark

Something failed rather than came back empty. The mark stays until a dictation succeeds, so a
breakage that persists looks like it. The reason is in `~/.local/share/phona/app.log`, on the
line beginning `daemon error`.

If it reads `No such file or directory: 'ffmpeg'`, the engine cannot find ffmpeg. Whisper
shells out to it by name, and an app opened from the Dock, from Spotlight or as a login item
is handed a PATH with no Homebrew in it, which the engine inherits. Phona now looks in the
usual Homebrew locations itself, so this needs an actual missing ffmpeg to happen:

```bash
brew install ffmpeg
```

The engine names the binary it settled on at every start, so its log says which one is in use:

```bash
grep ffmpeg ~/.local/share/phona/phonad.log
```

## The transcript was discarded as noise

The repetition guard caught a hallucination loop with no usable text in front of it. Where a
loop follows real speech the tail is cut and the rest is delivered, and the count of dropped
words is the `trimmed` field of the history entry. Either way the untrimmed transcript stays
in `raw`, so check it with `phona history 1`. Lower `silence_max_db` if your microphone is
quiet.
