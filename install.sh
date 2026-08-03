#!/bin/bash
# Set up the phona speech engine.
#
# Installs the Python side into ~/.local/share/phona and downloads the models. The app
# talks to it over a unix socket. Run this once, then open phona.app.
set -euo pipefail

TARGET="$HOME/.local/share/phona"
SRC="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || die "phona needs an Apple Silicon Mac. The models run on MLX."

say "checking prerequisites"
command -v ffmpeg >/dev/null 2>&1 || {
  command -v brew >/dev/null 2>&1 || die "install Homebrew first, from https://brew.sh"
  say "installing ffmpeg"
  brew install ffmpeg
}

PYTHON_BIN=""
for candidate in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3 /usr/bin/python3; do
  [[ -x "$candidate" ]] && { PYTHON_BIN="$candidate"; break; }
done
[[ -n "$PYTHON_BIN" ]] || die "no python3 found"

mkdir -p "$TARGET"

say "installing the engine into $TARGET"
cp "$SRC/engine/phonad.py" "$SRC/engine/client.py" "$TARGET/"

if [[ ! -x "$TARGET/venv/bin/python" ]]; then
  say "creating the virtual environment"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$TARGET/venv"
  else
    "$PYTHON_BIN" -m venv "$TARGET/venv"
  fi
fi

say "installing mlx-whisper and mlx-lm, this takes a few minutes"
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$TARGET/venv/bin/python" -q mlx-whisper mlx-lm
else
  "$TARGET/venv/bin/python" -m pip install -q --upgrade pip
  "$TARGET/venv/bin/python" -m pip install -q mlx-whisper mlx-lm
fi

if [[ ! -f "$TARGET/config.json" ]]; then
  say "writing default settings"
  "$TARGET/venv/bin/python" - <<'PY'
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path.home() / ".local/share/phona"))
from phonad import DEFAULTS, CONFIG
CONFIG.write_text(json.dumps(DEFAULTS, indent=2) + "\n")
print("wrote", CONFIG)
PY
fi

say "warming the models, this downloads about 3.5 GB the first time"
"$TARGET/venv/bin/python" "$TARGET/phonad.py" &
DAEMON_PID=$!
for _ in $(seq 1 600); do
  if [[ -S "$TARGET/phonad.sock" ]]; then
    say "engine ready"
    break
  fi
  sleep 1
done
kill "$DAEMON_PID" 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
ln -sf "$TARGET/client.py" /dev/null 2>/dev/null || true
cat > "$HOME/.local/bin/phona" <<'EOF'
#!/bin/zsh
exec "$HOME/.local/share/phona/venv/bin/python" "$HOME/.local/share/phona/client.py" "$@"
EOF
chmod +x "$HOME/.local/bin/phona"

say "done"
cat <<'EOF'

Next: open phona.app. It will ask for two permissions.

  Accessibility  so it can see the Option key and type into your apps
  Microphone     so it can hear you

Then hold Option anywhere, speak, and let go.
EOF
