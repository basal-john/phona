#!/bin/bash
# Switch the correction or speech model and restart the engine.
#
#   ./switch-model.sh 8bit     correction: the 8-bit 4B, the default, safest on real dictation
#   ./switch-model.sh 4bit     correction: the 4-bit 4B, faster, changes meaning silently
#   ./switch-model.sh 8b       correction: Qwen3-8B, no better and larger
#   ./switch-model.sh qwen35   correction: Qwen3.5-4B, the successor to the current model
#   ./switch-model.sh gemma4   correction: Gemma 4 E4B, the size-matched rival
#   ./switch-model.sh whisper  speech: Whisper large-v3-turbo, slower, takes the dictionary hint
#   ./switch-model.sh parakeet speech: Parakeet TDT 0.6b v3, the default, no dictionary hint
#   ./switch-model.sh          print what is running now
#
# Measured 2026-09-14 on an M1 Pro, each model on its own daemon under PHONA_HOME so the
# two ran under the same conditions, speech on Parakeet, second tap to text end to end:
#
#              suite, 34 cases          median dictation
#                                   short <10s   mid 10-25s   long >25s
#   4B-4bit   32 exact  0 failed       0.75s       1.43s       2.65s
#   4B-8bit   33 exact  0 failed       1.05s       1.82s       4.27s
#
# 4-bit is the faster model and it is still the wrong default. The suite does not separate
# them, 0 strict failures either way, because the suite is one-line cases and the damage
# shows up on real dictation. Replaying 40 real takes through both, 19 came back identical
# and 21 differed, and three of the differences changed what the speaker said:
#
#   - "write it in my voice, the way I usually do" came back as "in your voice, the way you
#     normally do", twice in one message, so the instruction is inverted
#   - "Amazing achievements, Ashok. These are some of the big ones you've done" lost its
#     first sentence, so the greeting and the name of the person it was addressed to went
#   - "check my DMs with them", an instruction to the assistant, came back as "I'll check my
#     DMs with each of them", which is the speaker doing it instead
#
# None of the three tripped the guard. 4-bit was guarded on 4 of 40 against 8-bit's 5, and
# on the birthday dictation 8-bit caught itself and retried where 4-bit returned a confident
# wrong answer. A dropped run of three words sits under MAX_DROPPED_RUN, which is four.
# That is the case against 4-bit: not that it is worse on average, but that it is worse
# silently, on messages addressed to named colleagues.
#
# The note this header used to carry, that 4-bit fails "translate this into german for me"
# by translating it, no longer reproduces. Both models correct it and leave it a request.
#
# Qwen3-8B, Qwen3.5-4B and Gemma 4 were not re-measured in this run, so they carry no
# numbers here rather than stale ones.
#
# Parakeet takes neither a language nor an initial prompt, so switching to it drops the
# dictionary hint. The daemon logs that at startup rather than failing.
set -euo pipefail

CONFIG="$HOME/.local/share/phona/config.json"
KEY="llm_model"

current() {
    "$HOME/.local/share/phona/venv/bin/python" -c \
        "import json,sys;print(json.load(open('$CONFIG')).get(sys.argv[1]) or 'not set')" "$KEY"
}

case "${1:-}" in
    8bit)     TARGET="mlx-community/Qwen3-4B-Instruct-2507-8bit" ;;
    4bit)     TARGET="mlx-community/Qwen3-4B-Instruct-2507-4bit" ;;
    8b)       TARGET="mlx-community/Qwen3-8B-4bit" ;;
    qwen35)   TARGET="mlx-community/Qwen3.5-4B-8bit" ;;
    gemma4)   TARGET="mlx-community/gemma-4-e4b-it-8bit" ;;
    whisper)  KEY="stt_model"; TARGET="mlx-community/whisper-large-v3-turbo" ;;
    parakeet) KEY="stt_model"; TARGET="mlx-community/parakeet-tdt-0.6b-v3" ;;
    "")       echo "correction: $(current)"
              KEY="stt_model"
              echo "speech:     $(current)"
              exit 0 ;;
    *)        echo "unknown option '$1', expected 8bit, 4bit, 8b, qwen35, gemma4, whisper or parakeet" >&2
              exit 1 ;;
esac

if [[ "$(current)" == "$TARGET" ]]; then
    echo "already running $TARGET"
    exit 0
fi

cp "$CONFIG" "$CONFIG.bak-switch"
"$HOME/.local/share/phona/venv/bin/python" - "$KEY" "$TARGET" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.local/share/phona/config.json")
cfg = json.load(open(path))
cfg[sys.argv[1]] = sys.argv[2]
json.dump(cfg, open(path, "w"), indent=2)
PY

echo "switching $KEY to $TARGET"
# The rollback below is the whole point of the backup, and `set -e` would exit before
# reaching it if the restart returned non-zero.
"$HOME/.local/bin/phona" restart >/dev/null 2>&1 || true

for _ in $(seq 1 80); do
    if tail -5 "$HOME/.local/share/phona/phonad.log" | grep -q "engine ready"; then
        echo "ready: $(current)"
        rm -f "$CONFIG.bak-switch"
        exit 0
    fi
    sleep 3
done

echo "engine did not report ready, rolling back" >&2
cp "$CONFIG.bak-switch" "$CONFIG"
rm -f "$CONFIG.bak-switch"
"$HOME/.local/bin/phona" restart >/dev/null 2>&1 || true
exit 1
