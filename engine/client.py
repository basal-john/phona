"""phona client. Records audio, then asks the warm phona daemon to transcribe and correct it.

Behaviour worth knowing before changing anything here:

- `--no-sound` exists so Hammerspoon can own the cues when it drives phona, which keeps the
  sound and the on-screen state change on the same frame.
- `warm` opens and immediately closes the input, so the first real dictation does not pay the
  cold device open, which is several seconds after boot.
- `mode` restarts the daemon, because the prompt prefix is prefilled per mode and has to be
  rebuilt before a change takes effect.
- `update-models` is deliberate and never automatic. New weights can change behaviour, so it
  is a decision rather than a side effect of an ordinary restart.
- `wrong` takes everything after the verb as what the user actually said, if they bothered.
- `start` never attaches to a recording already in flight. Doing so used to make the next
  hold adopt an orphaned ffmpeg, so one transcript silently covered both the abandoned audio
  and the new dictation. It also warms the daemon in the background, so the engine is ready
  by the time the user stops talking.
- `stop` hands the daemon a private copy of the wav. Transcription can take a second, and a
  new hold starting in that window would otherwise overwrite the very file being
  transcribed, since every recording uses the same path.

Recording lives here rather than in the daemon on purpose. macOS grants microphone
access to the responsible process, so a launchd daemon can never obtain it, while this
client inherits the grant of whatever launches it (Alfred, Terminal, a Shortcut).

Usage:
  phona                 toggle recording, print corrected text
  phona --paste         toggle, and paste the result at the cursor when done
  phona start|stop|cancel|status|ping
  phona fix "text"      correct text without recording, reads stdin when given no text
  phona clip            correct whatever is on the clipboard, in place
  phona models          show which models are loaded and at which revision
  phona update-models   deliberately fetch newer weights, then restart
  phona wrong ["..."]   flag the last dictation as wrong, optionally with the truth
  phona history [n]     show the last n dictations
  phona restart|stop-daemon|logs|config
Options:
  --mode grammar|polish|raw   override the configured correction mode
  --json                      print the raw daemon reply
  --quiet                     suppress stdout, useful with --paste
  --no-restore                leave the result on the clipboard after pasting
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

BASE = Path(os.environ.get("PHONA_HOME") or Path.home() / ".local/share/phona")
SOCK = BASE / "phonad.sock"
LOG = BASE / "phonad.log"
HISTORY = BASE / "history.jsonl"
CONFIG = BASE / "config.json"
DAEMON = BASE / "phonad.py"
PYTHON = BASE / "venv/bin/python"
REC = BASE / "recording.wav"
RECPID = BASE / "recording.pid"
RECMETA = BASE / "recording.json"
RECERR = BASE / "recording.err"
RECSTARTING = BASE / "recording.starting"
CLIENTLOG = BASE / "client.log"
MAX_LOG_BYTES = 2_000_000

FFMPEG = "/opt/homebrew/bin/ffmpeg"
PLIST_LABEL = "com.basalona.phonad"

SOUND_START = "/System/Library/Sounds/Tink.aiff"
SOUND_STOP = "/System/Library/Sounds/Pop.aiff"
SOUND_DONE = "/System/Library/Sounds/Glass.aiff"
SOUND_ERR = "/System/Library/Sounds/Basso.aiff"

STATE_WORDS = {
    "recording": "recording, run phona again to stop",
    "too_short": "too short, nothing transcribed",
    "empty": "no speech detected",
    "silent": "too quiet, nothing transcribed",
    "garbled": "transcription looked like noise, discarded",
    "cancelled": "cancelled",
    "idle": "not recording",
}

DEFAULT_CFG = {
    "input_device": ":default",
    "max_seconds": 300,
    "min_seconds": 0.4,
    "sounds": True,
}


def clog(msg):
    """Append to the client log.

    The client is normally spawned by Hammerspoon, where stdout and stderr go nowhere,
    so anything worth debugging has to be written to disk.
    """
    try:
        with open(CLIENTLOG, "a") as fh:
            fh.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def cfg():
    out = dict(DEFAULT_CFG)
    if CONFIG.exists():
        try:
            out.update(json.loads(CONFIG.read_text()))
        except Exception:
            pass
    return out


def play(path, enabled=True):
    if enabled:
        subprocess.Popen(["/usr/bin/afplay", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# -- daemon ----------------------------------------------------------------

def send(payload, timeout=900):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(str(SOCK))
    sock.sendall((json.dumps(payload) + "\n").encode())
    data = sock.makefile("r").readline()
    sock.close()
    return json.loads(data)


def daemon_alive():
    if not SOCK.exists():
        return False
    try:
        return send({"cmd": "PING"}, timeout=5).get("state") == "ready"
    except Exception:
        return False


def start_daemon(wait=240):
    listed = subprocess.run(["/bin/launchctl", "list", PLIST_LABEL],
                            capture_output=True).returncode == 0
    if listed:
        subprocess.run(["/bin/launchctl", "kickstart", f"gui/{os.getuid()}/{PLIST_LABEL}"],
                       capture_output=True)
    else:
        subprocess.Popen([str(PYTHON), str(DAEMON)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    deadline = time.time() + wait
    while time.time() < deadline:
        if daemon_alive():
            return True
        time.sleep(0.4)
    return False


def ensure_daemon(quiet):
    if daemon_alive():
        return True
    if not quiet:
        print("phona: daemon not running, starting and loading models (first run is slow)...",
              file=sys.stderr)
    if start_daemon():
        return True
    print(f"phona: daemon failed to start, see {LOG}", file=sys.stderr)
    return False


# -- recording -------------------------------------------------------------

def recording_pid():
    """Return the live capture pid, or None.

    Checking that some process holds the pid is not enough. A stale pid file can outlive
    its process and the number gets recycled, which would send SIGKILL to an unrelated
    process and let a dead session look alive. Confirm the command really is our capture.

    The exception is a session still starting up. Popen returns the child pid before it
    has finished exec'ing ffmpeg, so ps still shows the forked interpreter. That pid is
    ours, just not renamed yet.
    """
    if not RECPID.exists():
        return None
    try:
        pid = int(RECPID.read_text().strip())
    except Exception:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    if RECSTARTING.exists():
        return pid
    proc = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                          capture_output=True, text=True)
    if "avfoundation" not in proc.stdout:
        clog(f"pid {pid} is not our capture, discarding stale pid file")
        RECPID.unlink(missing_ok=True)
        RECMETA.unlink(missing_ok=True)
        return None
    return pid


def wait_for_pid(timeout=6.0):
    """Wait out an in-flight `start` so a quick tap cannot slip between the two processes.

    `start` and `stop` are separate processes. Without this, releasing Option before the
    pid file is written makes stop conclude nothing is recording, and ffmpeg is left
    running for the full max_seconds with nothing to stop it.
    """
    pid = recording_pid()
    if pid or not RECSTARTING.exists():
        return pid
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = recording_pid()
        if pid:
            return pid
        if not RECSTARTING.exists():
            return recording_pid()
        time.sleep(0.05)
    return recording_pid()


def begin_recording(conf):
    """Start capturing, and return once the device is producing audio.

    Four details here are all load-bearing, and each one was a bug first.

    The session is claimed before anything is spawned, and the pid is written before the
    device wait, because `start` and `stop` are separate processes. A push-to-talk release
    landing during the open would otherwise find nothing to stop, leaving ffmpeg recording
    for the full `max_seconds`.

    ffmpeg's stderr goes to a file rather than a pipe. This client exits while ffmpeg keeps
    running, and a pipe whose reader has gone away would kill the recording.

    The cue is withheld until the file is actually growing. avfoundation takes about half a
    second on a warm device and several seconds the first time after boot, and cueing early
    loses the opening words. The warm case still breaks out in about half a second, so the
    generous ceiling costs nothing.

    A session reclaimed mid-open takes our own child down with it, since ffmpeg would
    otherwise keep recording with nothing left to stop it.
    """
    RECSTARTING.write_text(str(time.time()))
    REC.unlink(missing_ok=True)
    errlog = open(RECERR, "w")
    proc = subprocess.Popen(
        [FFMPEG, "-y", "-loglevel", "error",
         "-f", "avfoundation", "-i", conf["input_device"],
         "-flush_packets", "1",
         "-t", str(conf["max_seconds"]),
         "-ar", "16000", "-ac", "1", str(REC)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errlog,
        start_new_session=True)

    RECPID.write_text(str(proc.pid))
    RECMETA.write_text(json.dumps({"started": time.time(), "warm": False}))
    RECSTARTING.unlink(missing_ok=True)

    deadline = time.time() + float(conf.get("device_open_timeout", 6.0))
    started = False
    while time.time() < deadline:
        if recording_pid() is None:
            RECSTARTING.unlink(missing_ok=True)
            if proc.poll() is None:
                proc.kill()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            clog("session was reclaimed during device open, capture terminated")
            return True
        if REC.exists() and REC.stat().st_size > 2000:
            started = True
            break
        if proc.poll() is not None:
            break
        time.sleep(0.02)

    if proc.poll() is not None:
        errlog.close()
        RECPID.unlink(missing_ok=True)
        RECMETA.unlink(missing_ok=True)
        RECSTARTING.unlink(missing_ok=True)
        err = RECERR.read_text().strip() if RECERR.exists() else ""
        play(SOUND_ERR, conf["sounds"])
        hint = ""
        if "Input/output error" in err or "denied" in err.lower() or not err:
            hint = ("\nphona: the app running phona needs Microphone access in "
                    "System Settings > Privacy & Security > Microphone")
        clog(f"ffmpeg exited during open, rc={proc.returncode}, stderr={err!r}")
        print(f"phona: could not open the microphone. {err}{hint}", file=sys.stderr)
        return False

    if not started:
        clog("device did not start producing audio in time, capture may be wedged")

    RECMETA.write_text(json.dumps({"started": time.time(), "warm": started}))
    play(SOUND_START, conf["sounds"])
    clog(f"recording started, pid={proc.pid}, device={conf['input_device']}, warm={started}")
    return True


def end_recording(conf):
    pid = recording_pid()
    started = time.time()
    try:
        started = json.loads(RECMETA.read_text())["started"]
    except Exception:
        pass

    if pid:
        try:
            os.kill(pid, signal.SIGINT)
        except OSError:
            pass
        for _ in range(50):
            if recording_pid() is None:
                break
            time.sleep(0.1)
        if recording_pid() is not None:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass

    RECPID.unlink(missing_ok=True)
    RECMETA.unlink(missing_ok=True)
    RECSTARTING.unlink(missing_ok=True)
    play(SOUND_STOP, conf["sounds"])
    return time.time() - started


def abort_recording(conf):
    pid = recording_pid()
    if pid:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    RECPID.unlink(missing_ok=True)
    RECMETA.unlink(missing_ok=True)
    RECSTARTING.unlink(missing_ok=True)
    REC.unlink(missing_ok=True)
    play(SOUND_ERR, conf["sounds"])


# -- clipboard and pasting -------------------------------------------------

def get_clipboard():
    return subprocess.run(["/usr/bin/pbpaste"], capture_output=True, text=True).stdout


def set_clipboard(text):
    subprocess.run(["/usr/bin/pbcopy"], input=text, text=True, check=False)


def clipboard_has_non_text():
    """True when the clipboard holds something pbpaste cannot represent, such as an image.

    Those contents cannot be captured and put back, so the honest move is to leave them
    alone rather than silently destroy them.
    """
    proc = subprocess.run(["/usr/bin/osascript", "-e", "clipboard info"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return False
    info = proc.stdout.lower()
    return bool(info.strip()) and "string" not in info and "unicode text" not in info


def paste_at_cursor(text, restore=True):
    """Put text on the clipboard, send Cmd+V to the front app, then restore the clipboard.

    The old clipboard only goes back if ours is still the one sitting there. Restoring
    unconditionally would silently discard anything the user copied during the paste.
    """
    previous = get_clipboard() if restore else None
    if restore and not previous and clipboard_has_non_text():
        clog("clipboard holds non-text content, it cannot be restored after pasting")
        print("phona: your clipboard held an image or file. It has been replaced by the "
              "dictated text and cannot be restored.", file=sys.stderr)
    set_clipboard(text)
    time.sleep(0.08)
    result = subprocess.run(
        ["/usr/bin/osascript", "-e",
         'tell application "System Events" to keystroke "v" using command down'],
        capture_output=True, text=True)
    if result.returncode != 0:
        err = (result.stderr or "").strip()
        print(f"phona: paste failed, the text is on the clipboard instead. {err}",
              file=sys.stderr)
        print("phona: grant Accessibility to the app running phona in "
              "System Settings > Privacy & Security > Accessibility", file=sys.stderr)
        return False
    if restore and previous:
        time.sleep(0.3)
        if get_clipboard() == text:
            set_clipboard(previous)
        else:
            clog("clipboard changed during paste, leaving the newer content alone")
    return True


def load_history():
    if not HISTORY.exists():
        return []
    entries = []
    for line in HISTORY.read_text().splitlines():
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def set_mode(name):
    valid = ("grammar", "polish", "raw")
    if name not in valid:
        print(f"phona: mode must be one of {', '.join(valid)}", file=sys.stderr)
        return 2
    data = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    data["mode"] = name
    CONFIG.write_text(json.dumps(data, indent=2) + "\n")
    subprocess.run(["/usr/bin/pkill", "-f", "phonad.py"], capture_output=True)
    time.sleep(1)
    ok = start_daemon()
    print(f"mode set to {name}" if ok else f"mode set to {name}, daemon restart failed")
    return 0 if ok else 1


def show_history(count, search=None, since=None, export=None, plain=False, as_json=False):
    entries = load_history()
    if not entries:
        print(json.dumps([]) if as_json else "no history yet")
        return

    if search:
        needle = search.lower()
        entries = [e for e in entries
                   if needle in (e.get("raw", "") + e.get("text", "")).lower()]
    if since:
        entries = [e for e in entries if e.get("ts", "") >= since]
    if count and not export:
        entries = entries[-count:]

    if as_json:
        print(json.dumps(entries))
        return

    if not entries:
        print("nothing matched")
        return

    if export:
        lines = ["# phona dictation log", "",
                 f"{len(entries)} entries, exported {time.strftime('%Y-%m-%d %H:%M')}", ""]
        for e in entries:
            lines.append(f"## {e.get('ts')}")
            lines.append("")
            lines.append(f"- spoken: {e.get('seconds')}s, "
                         f"stt {e.get('stt_secs')}s, llm {e.get('llm_secs')}s, "
                         f"mode {e.get('mode')}")
            lines.append("")
            lines.append(f"**heard**: {e.get('raw', '')}")
            lines.append("")
            lines.append(f"**corrected**: {e.get('text', '')}")
            lines.append("")
        Path(export).expanduser().write_text("\n".join(lines))
        print(f"exported {len(entries)} entries to {export}")
        return

    for e in entries:
        if plain:
            print(e.get("text", ""))
            continue
        src = e.get("source", "voice")
        print(f"{e.get('ts')}  {e.get('seconds')}s  "
              f"stt={e.get('stt_secs')}s llm={e.get('llm_secs')}s  [{e.get('mode')}/{src}]")
        print(f"  raw: {e.get('raw', '')}")
        print(f"  fix: {e.get('text', '')}")


# -- main ------------------------------------------------------------------

def deliver(reply, do_paste, quiet, restore, cmd):
    state = reply.get("state")
    clog(f"result state={state} text={(reply.get('text') or '')[:80]!r} "
         f"raw={(reply.get('raw') or '')[:80]!r}")
    if state == "error":
        play(SOUND_ERR)
        print(f"phona: {reply.get('error')}", file=sys.stderr)
        return 1

    text = reply.get("text") or ""
    if state == "done" and text:
        play(SOUND_DONE, cfg()["sounds"])
        if do_paste:
            paste_at_cursor(text, restore=restore)
        elif cmd != "clip":
            set_clipboard(text)
        if not quiet:
            print(text)
        return 0

    play(SOUND_ERR, cfg()["sounds"])
    if not quiet:
        print(STATE_WORDS.get(state, state), file=sys.stderr)
        if reply.get("raw"):
            print(f"  heard: {reply['raw'][:120]}", file=sys.stderr)
    return 1


def main():
    args = list(sys.argv[1:])
    mode = None
    as_json = quiet = do_paste = False
    restore = True
    hist_search = hist_since = hist_export = None
    hist_all = hist_plain = no_sound = False
    rest = []

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--mode" and i + 1 < len(args):
            mode, i = args[i + 1], i + 2
            continue
        if a in ("--search", "--grep") and i + 1 < len(args):
            hist_search, i = args[i + 1], i + 2
            continue
        if a == "--since" and i + 1 < len(args):
            hist_since, i = args[i + 1], i + 2
            continue
        if a == "--export" and i + 1 < len(args):
            hist_export, i = args[i + 1], i + 2
            continue
        if a == "--all":
            hist_all = True
            i += 1
            continue
        if a == "--today":
            hist_since, i = time.strftime("%Y-%m-%d"), i + 1
            continue
        if a == "--plain":
            hist_plain = True
            i += 1
            continue
        if a.startswith("--mode="):
            mode = a.split("=", 1)[1]
        elif a == "--json":
            as_json = True
        elif a == "--quiet":
            quiet = True
        elif a in ("--paste", "-p"):
            do_paste = True
        elif a == "--no-restore":
            restore = False
        elif a == "--no-sound":
            no_sound = True
        elif a in ("--help", "-h"):
            print(__doc__)
            return 0
        else:
            rest.append(a)
        i += 1

    cmd = rest[0].lower() if rest else "toggle"
    conf = cfg()
    if no_sound:
        conf["sounds"] = False

    if cmd == "history":
        count = 5
        if len(rest) > 1 and rest[1].isdigit():
            count = int(rest[1])
        if hist_all:
            count = 0
        show_history(count, search=hist_search, since=hist_since,
                     export=hist_export, plain=hist_plain, as_json=as_json)
        return 0
    if cmd == "models":
        reply = None
        if daemon_alive():
            reply = send({"cmd": "STATUS"})
        conf = cfg()
        print(f"speech    {conf.get('stt_model')}")
        print(f"          revision {(reply or {}).get('stt_revision') or 'not cached'}")
        print(f"grammar   {conf.get('llm_model')}")
        print(f"          revision {(reply or {}).get('llm_revision') or 'not cached'}")
        stt_pin = (reply or {}).get("stt_pinned")
        llm_pin = (reply or {}).get("llm_pinned")
        if reply is None:
            print("pinned    unknown, the engine is not running")
        else:
            print(f"pinned    speech {bool(stt_pin)}, grammar {bool(llm_pin)}")
        print()
        print("Change a model by editing stt_model or llm_model in config.json, then")
        print("run 'phona restart'. Refresh the pinned weights with 'phona update-models'.")
        return 0

    if cmd == "update-models":
        conf = cfg()
        print("fetching the latest weights for:")
        print(f"  {conf.get('stt_model')}")
        print(f"  {conf.get('llm_model')}")
        env = dict(os.environ)
        env.pop("HF_HUB_OFFLINE", None)
        code = subprocess.run(
            [str(PYTHON), "-c",
             "import sys;from huggingface_hub import snapshot_download;"
             "[snapshot_download(r) for r in sys.argv[1:]]",
             conf.get("stt_model"), conf.get("llm_model")],
            env=env).returncode
        if code != 0:
            print("phona: download failed", file=sys.stderr)
            return 1
        subprocess.run(["/usr/bin/pkill", "-f", "phonad.py"], capture_output=True)
        time.sleep(1)
        start_daemon()
        print("done. run 'phona models' to see the new revisions")
        return 0

    if cmd == "wrong":
        actual = " ".join(rest[1:]) if len(rest) > 1 else None
        if not ensure_daemon(quiet):
            return 1
        reply = send({"cmd": "FLAG", "actual": actual})
        if reply.get("state") != "done":
            print(f"phona: {reply.get('error')}", file=sys.stderr)
            return 1
        print("flagged. run /phona-audit to see what it suggests")
        if reply.get("heard"):
            print(f"  heard: {reply['heard'][:100]}")
        return 0
    if cmd == "mode":
        if len(rest) < 2:
            print(cfg().get("mode", "grammar"))
            return 0
        return set_mode(rest[1].lower())
    if cmd == "logs":
        print(LOG.read_text() if LOG.exists() else "no log yet", end="")
        return 0
    if cmd == "config":
        print(CONFIG.read_text() if CONFIG.exists() else "no config yet", end="")
        return 0
    if cmd == "cancel":
        abort_recording(conf)
        print("cancelled", file=sys.stderr)
        return 0
    if cmd == "warm":
        tmp = BASE / "_devwarm.wav"
        t0 = time.time()
        subprocess.run(
            [FFMPEG, "-y", "-loglevel", "error", "-f", "avfoundation",
             "-i", conf["input_device"], "-t", "0.4", "-ar", "16000", "-ac", "1", str(tmp)],
            capture_output=True, timeout=30)
        tmp.unlink(missing_ok=True)
        clog(f"device warmed in {time.time() - t0:.2f}s")
        if not quiet:
            print(f"input device warmed in {time.time() - t0:.2f}s")
        return 0
    if cmd == "stop-daemon":
        if subprocess.run(["/bin/launchctl", "list", PLIST_LABEL],
                          capture_output=True).returncode == 0:
            subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{PLIST_LABEL}"],
                           capture_output=True)
        subprocess.run(["/usr/bin/pkill", "-f", "phonad.py"], capture_output=True)
        print("daemon stopped")
        return 0
    if cmd == "restart":
        subprocess.run(["/usr/bin/pkill", "-f", "phonad.py"], capture_output=True)
        time.sleep(1)
        ok = start_daemon()
        print("daemon restarted" if ok else f"restart failed, see {LOG}")
        return 0 if ok else 1

    if cmd in ("toggle", "start", "stop"):
        active = (wait_for_pid() if cmd in ("stop", "toggle") else recording_pid()) is not None

        if cmd == "start" or (cmd == "toggle" and not active):
            if active:
                clog("a recording was already in flight, discarding it and starting fresh")
                abort_recording(conf)
            if not daemon_alive():
                subprocess.Popen([str(PYTHON), __file__, "ping", "--quiet"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            if not begin_recording(conf):
                return 1
            if not quiet:
                print("recording, run phona again to stop", file=sys.stderr)
            return 0

        if not active:
            if not quiet:
                print("not recording", file=sys.stderr)
            return 1

        seconds = end_recording(conf)
        size = REC.stat().st_size if REC.exists() else 0
        clog(f"recording stopped after {seconds:.2f}s, wav bytes={size}")
        if seconds < conf["min_seconds"] or not REC.exists():
            play(SOUND_ERR, conf["sounds"])
            if not quiet:
                print("too short, nothing transcribed", file=sys.stderr)
            REC.unlink(missing_ok=True)
            return 1

        take = BASE / f"take-{os.getpid()}-{int(time.time() * 1000)}.wav"
        try:
            REC.replace(take)
        except OSError as exc:
            clog(f"could not stage the recording: {exc}")
            take = REC

        if not ensure_daemon(quiet):
            take.unlink(missing_ok=True)
            return 1
        try:
            reply = send({"cmd": "PROCESS", "path": str(take),
                          "seconds": seconds, "mode": mode})
        except Exception as exc:
            clog(f"daemon request failed: {exc!r}")
            play(SOUND_ERR, conf["sounds"])
            print(f"phona: could not reach the daemon. {exc}", file=sys.stderr)
            return 1
        finally:
            take.unlink(missing_ok=True)

        if as_json:
            print(json.dumps(reply, indent=2))
            return 0
        return deliver(reply, do_paste, quiet, restore, cmd)

    if not ensure_daemon(quiet):
        return 1

    if cmd in ("status", "ping"):
        reply = send({"cmd": cmd.upper()})
        if not quiet:
            print(json.dumps(reply, indent=2))
        return 0
    if cmd == "fix":
        text = " ".join(rest[1:]) if len(rest) > 1 else sys.stdin.read()
        reply = send({"cmd": "FIX", "text": text, "mode": mode})
    elif cmd == "clip":
        reply = send({"cmd": "FIX", "text": get_clipboard(), "mode": mode})
        if reply.get("text"):
            set_clipboard(reply["text"])
    else:
        print(f"phona: unknown command '{cmd}', try phona --help", file=sys.stderr)
        return 2

    if as_json:
        print(json.dumps(reply, indent=2))
        return 0
    return deliver(reply, do_paste, quiet, restore, cmd)


if __name__ == "__main__":
    sys.exit(main())
