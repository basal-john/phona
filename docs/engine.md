# phona

Voice to grammar-corrected text, fully local, on Apple Silicon.

Press a hotkey, speak, press it again. The corrected text is pasted where your cursor is.
Nothing leaves the machine.

## Pipeline

```
mic -> ffmpeg (16 kHz mono) -> silence gate -> Whisper large-v3-turbo
    -> repetition guard -> Qwen3-4B grammar pass -> clipboard -> paste at cursor
```

Whisper was chosen over Parakeet on measured evidence. On 12 sentences with deliberate
grammar errors, Whisper large-v3-turbo preserved 12 of 12 errors for the LLM to fix.
Parakeet TDT silently repaired 2 of them during transcription, which destroys the signal
the correction stage exists to catch.

## Layout

| Path | Purpose |
| --- | --- |
| `~/.local/bin/phona` | CLI entry point |
| `~/.local/share/phona/phonad.py` | daemon holding the warm models |
| `~/.local/share/phona/client.py` | records audio, talks to the daemon, pastes |
| `~/.local/share/phona/config.json` | settings |
| `~/.local/share/phona/history.jsonl` | every dictation, raw and corrected |
| `~/.local/share/phona/phonad.log` | daemon log |
| `~/Library/LaunchAgents/com.basalona.phonad.plist` | starts the daemon at login |
| `~/.hammerspoon/init.lua` | the Hammerspoon fallback, still hold-Option push to talk |

Recording lives in the client, not the daemon, on purpose. macOS grants microphone access
per responsible process, and a launchd daemon can never prompt for it. The client inherits
the grant of whatever launches it, so Alfred or Terminal owns the permission.

## Commands

```
phona                    toggle recording, print corrected text
phona --paste            toggle, paste the result at the cursor
phona fix "some text"    correct text without recording
phona clip               correct the clipboard in place
phona history 10         last 10 entries, raw next to corrected
phona history --all      everything ever dictated or corrected
phona history --today    just today
phona history --search "jira"    entries mentioning a word
phona history --plain    corrected text only, one per line, pipe friendly, newlines escaped as \n
phona history --all --export ~/log.md    write the whole log as markdown
phona status             models and cached prefix size
phona restart            reload the daemon after a config change
phona logs               daemon log
tail ~/.local/share/phona/client.log    recording and paste side, the Hammerspoon path
```

Audio cues: Tink means recording, Pop means stopped, Glass means text ready, Basso means
nothing usable was captured.

## Tap Option to talk

Tap the left Option key on its own, speak, tap it again. The corrected text is pasted at
the cursor.

The Hammerspoon fallback described at the end of this section is the exception. It is still
hold to talk and was left that way.

A small capsule rises near the bottom of whichever display you are working on and moves
through three states:

| State | What you see | What is happening |
| --- | --- | --- |
| Listening | five bars tracking your voice | the microphone is open |
| Working | bars settle into a travelling ripple | transcribing and correcting |
| Done | a green check, then the capsule sinks away | text is on its way to the cursor |

The waveform is the real input level, read from the tail of the wav as it is written, not
a decorative loop. If it stays flat while you talk, the microphone is not picking you up.

Motion is spring-driven rather than fixed-duration, so every state change begins from
whatever is on screen at that instant and can be interrupted mid-flight. The capsule
leaves along the path it arrived on. Springs use Apple's two parameters, damping ratio
and response, and are critically damped, since overshoot on something that merely
appeared reads as noise rather than physics.

Sound is triggered from the same code that changes the visual state, so the cue and the
animation land on the same frame instead of drifting apart across two processes.

Reduced Motion replaces the springs with a plain cross fade and drops the lift and scale.
Reduced Transparency makes the capsule solid. Both are read from your accessibility
settings at load, so toggle one and then reload phona.

The app watches the key itself. Option is only observed, never remapped, so Option+click,
Option+e and every other Option shortcut keep working. The decision is taken on the release
rather than the press, since a press is how a shortcut starts too, and a press lasting longer
than 500 ms is a rest on the key rather than a tap. `TapToggle` in `PhonaCore` holds the whole
decision and its tests hold the behaviour.

An older Hammerspoon fallback lives at `~/.hammerspoon/init.lua`, kept as it was: hold to
talk, a hold counting once Option has been down alone for 250 ms, and any key during the hold
abandoning the recording.

Hammerspoon needs two permissions, both under System Settings, Privacy & Security:

- **Accessibility**, for the key watcher and for pasting
- **Microphone**, prompted the first time you start a dictation

Tuning the fallback: `HOLD_DELAY` at the top of `init.lua` sets how long Option must be down
before recording starts. Reload with Control+Option+Command+R, or from the Hammerspoon menu.

To use a different trigger instead, `phona --paste` is a plain command and can be bound
from Shortcuts.app, Alfred with Powerpack, Raycast or Karabiner-Elements.

## Menu bar

A microphone icon sits in the menu bar, served by Hammerspoon. It gives you:

- the last 12 dictations, newest first, click one to copy it back to the clipboard
- hover any entry to see what Whisper actually heard before correction
- export the whole log as markdown and reveal it in Finder
- open the history file, the settings file or this README
- warm the microphone, restart the daemon, reload phona

## Config

`~/.local/share/phona/config.json`, then `phona restart`.

| Key | Default | Meaning |
| --- | --- | --- |
| `stt_model` | `whisper-large-v3-turbo` | any mlx-community Whisper repo |
| `llm_model` | `Qwen3-4B-Instruct-2507-4bit` | any mlx-lm chat model |
| `language` | `en` | set to `auto` to detect, or `de` for German |
| `input_device` | `:default` | avfoundation index, for example `:1` |
| `silence_max_db` | `-42.0` | quieter than this counts as silence |
| `max_words_per_second` | `6.0` | above this the transcript is treated as noise |
| `use_initial_prompt` | `false` | bias Whisper with the dictionary, raises hallucination risk |
| `dictionary` | `["Phona"]` | vocabulary hint, only used when the flag above is on |
| `replacements` | `{}` | literal fixes, applied before the layout pass, for example `{"jeera": "Jira"}` |
| `spoken_layout` | `true` | act on `new paragraph`, `new line`, `bullet point` spoken as a sentence of their own |
| `self_correction` | `true` | resolve a correction the speaker spoke aloud, "the iPhone app, sorry, the Mac app" |
| `keep_audio_days` | `0` | keep each recording for this many days under `audio/`, pruned on every run. Off by default. Honoured by the daemon, so it covers both the app and the CLI |
| `pin_models` | `true` | load the cached snapshot instead of re-resolving the hub |
| `model_update_check` | `true` | ask the hub whether the pinned weights are behind. Reports only, never downloads. The one outbound call outside an install or an explicit update |
| `min_seconds` | `0.4` | shorter recordings are discarded as a slip of the key |
| `device_open_timeout` | `6.0` | seconds to wait for the input to start producing audio |
| `sounds` | `true` | audio cues |

## Measured performance

On this machine, after the daemon is warm:

| Stage | Time |
| --- | --- |
| Whisper, short utterance | about 0.75 s |
| Grammar pass, prefix cache warm | about 0.44 s |
| End to end after you stop speaking | about 1.2 s |

The daemon prefills the KV cache with the fixed system prompt and few-shot examples,
which cut the grammar pass from 1.35 s to 0.44 s. Cold start is about 50 s the very first
time (model download) and about 7 s afterwards, paid once at login.

## Troubleshooting

**Nothing records, or ffmpeg hangs.** CoreAudio input can wedge if a capture process is
killed mid-recording. Check with:

```
ffmpeg -f avfoundation -i ":default" -t 2 -ar 16000 -ac 1 /tmp/t.wav
```

If that hangs instead of finishing in about two seconds, restart the audio daemon with
`sudo killall coreaudiod`, or unplug and replug the USB microphone.

**"could not open the microphone".** Grant Microphone access to the app that launches
phona, in System Settings, Privacy & Security, Microphone.

**Paste does nothing.** The text is still on the clipboard. Grant Accessibility to the
launching app.

**The first dictation after boot comes back silent.** A cold input device takes about
four seconds to start producing audio, against about 0.9 s once warm. Hammerspoon runs
`phona warm` three seconds after load to absorb that. Run `phona warm` by hand if a long
idle period puts the microphone back to sleep, or raise `device_open_timeout`.

**Transcript is discarded as noise.** The repetition guard caught a Whisper hallucination
loop with no usable text in front of it. Where a loop follows real speech the tail is cut
and the rest is delivered, and the count of dropped words is the `trimmed` field of the
history entry. Either way the untrimmed transcript stays in `raw`, so check it with
`phona history 1`. Lower `silence_max_db` if your microphone is quiet.
