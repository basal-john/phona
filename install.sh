#!/bin/bash
# Set up the phona speech engine.
#
# Installs the Python side into ~/.local/share/phona and downloads the models. The app
# talks to it over a unix socket. Run this once, then open phona.app.
set -euo pipefail

# Overridable so the installer can be tested without touching a real install.
TARGET="${PHONA_HOME:-$HOME/.local/share/phona}"
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
cp "$SRC/engine/phonad.py" "$SRC/engine/client.py" "$SRC/engine/audit.py" "$SRC/engine/model_updates.py" \
   "$SRC/engine/history_file.py" "$TARGET/"

# switch-model.sh is the only correct way to change model. It backs the config up, waits
# for the engine to report ready and rolls back if it never does, so the Models pane sends
# people here rather than at the config file.
cp "$SRC/switch-model.sh" "$TARGET/"
chmod +x "$TARGET/switch-model.sh"

if [[ ! -x "$TARGET/venv/bin/python" ]]; then
  say "creating the virtual environment"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$TARGET/venv"
  else
    "$PYTHON_BIN" -m venv "$TARGET/venv"
  fi
fi

say "installing mlx-whisper, mlx-lm and parakeet-mlx, this takes a few minutes"
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$TARGET/venv/bin/python" -q mlx-whisper mlx-lm parakeet-mlx
else
  "$TARGET/venv/bin/python" -m pip install -q --upgrade pip
  "$TARGET/venv/bin/python" -m pip install -q mlx-whisper mlx-lm parakeet-mlx
fi

# Settings are not written here. The daemon writes its defaults on first run,
# and duplicating that meant a second copy of the path logic to get wrong.

if [[ -n "${PHONA_SKIP_MODELS:-}" ]]; then
  say "skipping the model warmup"
else
  say "warming the models, this fetches about 6.5 GB the first time and keeps it on disk"
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
fi

# The `phona` command, pointed at whichever install this run set up.
#
# Only written for a real install. `PHONA_HOME` exists so the installer can be exercised
# against a throwaway directory, and CI does exactly that with `PHONA_HOME=/tmp/phona-ci`.
# Writing the shared shim on those runs pointed the user's own `phona` command into a
# temporary directory, which works until /tmp is cleared and then fails with no clue why.
# It happened on this machine. A test install now gets its shim inside its own target and
# leaves the real one alone.
#
# The condition is whether PHONA_HOME is unset or empty, not where it points, because that
# is the actual question and because comparing against the default would restate the path
# here. Empty counts as unset on purpose: TARGET is expanded with the same `:-` default, so
# `PHONA_HOME=` already means an ordinary install, and the two have to agree.
#
# A run that sets PHONA_HOME to the default path gets its shim at $TARGET/phona, which
# still works and is the same file the default install would have written anyway.
if [[ -z "${PHONA_HOME:-}" ]]; then
  SHIM="$HOME/.local/bin/phona"
  mkdir -p "$HOME/.local/bin"
else
  SHIM="$TARGET/phona"
  say "PHONA_HOME is set, so the phona command goes to $SHIM and the shared one is untouched"
fi

cat > "$SHIM" <<EOF
#!/bin/zsh
exec "$TARGET/venv/bin/python" "$TARGET/client.py" "\$@"
EOF
chmod +x "$SHIM"

say "done"
cat <<'EOF'

Next: open phona.app. It will ask for two permissions.

  Accessibility  so it can see the Option key and type into your apps
  Microphone     so it can hear you

Then hold Option anywhere, speak, and let go.
EOF
