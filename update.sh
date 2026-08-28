#!/bin/bash
# Pull the latest Phona and rebuild everything in one step.
#
# Safe to run repeatedly. Keeps your settings, history and flagged corrections, since all
# of that lives in ~/.local/share/phona and is never touched here.
set -euo pipefail

cd "$(dirname "$0")"
TARGET="$HOME/.local/share/phona"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }

say "fetching"
BEFORE="$(git rev-parse --short HEAD)"
git pull --ff-only
AFTER="$(git rev-parse --short HEAD)"

if [[ "$BEFORE" == "$AFTER" ]]; then
  say "already up to date at $AFTER"
else
  say "updated $BEFORE to $AFTER"
  git --no-pager log --oneline "$BEFORE..$AFTER" | sed 's/^/    /'
fi

say "updating the engine"
cp engine/phonad.py engine/client.py engine/audit.py engine/model_updates.py "$TARGET/"

# New dependencies land rarely, but a pull that adds one would otherwise fail at runtime.
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$TARGET/venv/bin/python" -q mlx-whisper mlx-lm parakeet-mlx
else
  "$TARGET/venv/bin/python" -m pip install -q mlx-whisper mlx-lm parakeet-mlx
fi

say "rebuilding the app"
cd macapp && ./build.sh >/dev/null && cd ..

say "reinstalling"
osascript -e 'quit app "Phona"' 2>/dev/null || pkill -x PhonaApp 2>/dev/null || true
sleep 1
rm -rf /Applications/Phona.app
cp -R macapp/build/Phona.app /Applications/Phona.app

# The staged copy is dropped once it is installed. Left behind it is a second launchable
# Phona in Spotlight and Launchpad, carrying the same bundle identifier and the same
# designated requirement as the real one, so opening the wrong one looks identical and
# goes stale the moment the next version is installed.
rm -rf macapp/build/Phona.app

say "restarting the engine"
pkill -f phonad.py 2>/dev/null || true
open -a /Applications/Phona.app

say "done, version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macapp/Resources/Info.plist)"
echo
echo "Your settings and history were not touched. Permissions carry over, because the"
echo "signature is pinned to the bundle identifier rather than the build."
