#!/bin/bash
# Switch the correction model and restart the engine.
#
#   ./switch-model.sh 8bit     the 8-bit 4B, 29 of 29 on the suite, slower on long dictation
#   ./switch-model.sh 4bit     the 4-bit 4B, 28 of 29, the fastest
#   ./switch-model.sh 8b       Qwen3-8B, 28 of 29, no better and larger
#   ./switch-model.sh          print what is running now
#
# Measured on this machine, whole suite through the real daemon:
#
#   4B-4bit   28 exact  1 failed   short 0.44s  mid 1.09s  long 2.95s
#   4B-8bit   29 exact  0 failed   short 0.50s  mid 1.50s  long 4.19s
#   8B-4bit   28 exact  0 failed   about the same as 8bit and 4 GB larger
#
# The one case 4-bit fails is "translate this into german for me", which it
# translates instead of correcting. 8-bit corrects it and leaves it a request.
set -euo pipefail

CONFIG="$HOME/.local/share/phona/config.json"

current() {
    "$HOME/.local/share/phona/venv/bin/python" -c \
        "import json;print(json.load(open('$CONFIG'))['llm_model'])"
}

case "${1:-}" in
    8bit) TARGET="mlx-community/Qwen3-4B-Instruct-2507-8bit" ;;
    4bit) TARGET="mlx-community/Qwen3-4B-Instruct-2507-4bit" ;;
    8b)   TARGET="mlx-community/Qwen3-8B-4bit" ;;
    "")   echo "running: $(current)"; exit 0 ;;
    *)    echo "unknown option '$1', expected 8bit, 4bit or 8b" >&2; exit 1 ;;
esac

if [[ "$(current)" == "$TARGET" ]]; then
    echo "already running $TARGET"
    exit 0
fi

cp "$CONFIG" "$CONFIG.bak-switch"
"$HOME/.local/share/phona/venv/bin/python" - "$TARGET" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.local/share/phona/config.json")
cfg = json.load(open(path))
cfg["llm_model"] = sys.argv[1]
json.dump(cfg, open(path, "w"), indent=2)
PY

echo "switching to $TARGET"
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
