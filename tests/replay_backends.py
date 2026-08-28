"""Replay your own retained recordings through two speech models and diff the results.

The grammar suite feeds text straight to FIX, and a public corpus like LibriSpeech is other
people reading books aloud. Neither tells you whether a speech model handles your voice,
your microphone and the words you actually dictate. This does, using the recordings
`keep_audio_days` has already kept.

No ground truth is needed. Where both models produce the same text there is nothing to look
at, so the report only lists the takes where they disagree. That shortlist is short enough
to read, and reading it is the decision.

    python tests/replay_backends.py --collect whisper
    ./switch-model.sh parakeet
    python tests/replay_backends.py --collect parakeet
    python tests/replay_backends.py --report whisper parakeet

Nothing is written to your history, and nothing is archived. The daemon moves a retained
take into its audio directory, so a replay that let retention run would refill that
directory with its own copies and grow the corpus on every pass. Only `take-*.wav` is
replayed, which is what the app records, so a stray wav that landed in the directory some
other way is not mistaken for a dictation.
"""

import argparse
import difflib
import json
import pathlib
import re
import shutil
import socket
import tempfile
import time

BASE = pathlib.Path.home() / ".local/share/phona"
SOCK = BASE / "phonad.sock"
AUDIO = BASE / "audio"
HISTORY = BASE / "history.jsonl"
OUT = pathlib.Path(__file__).resolve().parent / "replays"
READ_THIS = 0.90


def spoken_words(text):
    """The words alone, so a model that punctuates is not scored against one that does not.

    Parakeet writes "So, this is the repo." where Whisper writes "so this is the repo", and
    comparing the raw strings called 93 of 115 takes different when only 72 differed by a
    word and 12 were worth a human reading. Digits are left as they are: across 115 real
    takes exactly one pair disagreed on a digit against a spelled number, which is not
    enough to justify carrying a number speller.
    """
    text = text.lower().replace("\u2019", "'")
    return " ".join(re.sub(r"[^a-z0-9' ]", " ", text).split())


def request(payload, timeout=600):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(str(SOCK))
    sock.sendall((json.dumps(payload) + "\n").encode())
    line = sock.makefile("r").readline()
    sock.close()
    return json.loads(line)


def takes():
    """Every retained recording, with the text the daemon produced for it at the time.

    History is keyed by basename and a name can appear more than once, so the newest entry
    wins. A recording with no surviving entry is still worth replaying, it just has no
    original to compare against.
    """
    produced = {}
    if HISTORY.exists():
        for line in HISTORY.read_text().splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("source") == "voice" and row.get("audio"):
                produced[row["audio"]] = row
    found = []
    for wav in sorted(AUDIO.glob("take-*.wav")):
        row = produced.get(wav.name, {})
        found.append({"audio": wav.name, "path": wav,
                      "seconds": row.get("seconds") or 0.0,
                      "was": row.get("text", ""), "when": row.get("ts", "")})
    return found


def collect(label):
    status = request({"cmd": "STATUS"})
    model = status.get("stt_model", "unknown")
    found = takes()
    if not found:
        print(f"no recordings in {AUDIO}. Set keep_audio_days and dictate for a few days.")
        return 1

    print(f"{label}: {len(found)} takes through {model}")
    OUT.mkdir(exist_ok=True)
    rows = []
    started = time.time()
    with tempfile.TemporaryDirectory() as scratch:
        for i, take in enumerate(found, 1):
            copy = pathlib.Path(scratch) / take["audio"]
            shutil.copy2(take["path"], copy)
            reply = request({"cmd": "PROCESS", "path": str(copy),
                             "seconds": take["seconds"],
                             "history": False, "retain": False})
            rows.append({**{k: take[k] for k in ("audio", "seconds", "was", "when")},
                         "state": reply.get("state"),
                         "raw": reply.get("raw", ""), "text": reply.get("text", ""),
                         "stt_secs": reply.get("stt_secs"),
                         "llm_secs": reply.get("llm_secs")})
            if i % 25 == 0 or i == len(found):
                print(f"  {i}/{len(found)}", flush=True)

    path = OUT / f"{label}.json"
    path.write_text(json.dumps({"model": model, "rows": rows}, indent=1))
    audio = sum(r["seconds"] for r in rows) or 1
    stt = sum(r["stt_secs"] or 0 for r in rows)
    print(f"wrote {path}")
    print(f"  {audio:.0f}s of audio, stt {stt:.0f}s, RTF {stt / audio:.3f}, "
          f"wall {time.time() - started:.0f}s")
    return 0


def report(left, right):
    one = json.loads((OUT / f"{left}.json").read_text())
    two = json.loads((OUT / f"{right}.json").read_text())
    by_audio = {r["audio"]: r for r in two["rows"]}
    shared = [(a, by_audio[a["audio"]]) for a in one["rows"] if a["audio"] in by_audio]

    def similarity(pair):
        return difflib.SequenceMatcher(
            None, spoken_words(pair[0]["raw"]), spoken_words(pair[1]["raw"])).ratio()

    differ = [pair for pair in shared
              if spoken_words(pair[0]["raw"]) != spoken_words(pair[1]["raw"])]
    differ.sort(key=similarity)
    read_these = [pair for pair in differ if similarity(pair) < READ_THIS]

    print(f"{left:10s} {one['model']}")
    print(f"{right:10s} {two['model']}")
    for side, data in ((left, one), (right, two)):
        audio = sum(r["seconds"] for r in data["rows"]) or 1
        stt = sum(r["stt_secs"] or 0 for r in data["rows"])
        print(f"  {side:10s} RTF {stt / audio:.3f}")

    print(f"\n{len(shared)} takes through both")
    print(f"  same words, ignoring case and punctuation : {len(shared) - len(differ)}")
    print(f"  a word apart                              : {len(differ) - len(read_these)}")
    print(f"  worth reading, below {READ_THIS:.2f} similarity     : {len(read_these)}")

    if not read_these:
        print("\nNothing to read. Neither model heard your recordings meaningfully "
              "differently.")
        return 0

    print("\nMost different first. Pick the better line in each pair.\n")
    for a, b in read_these:
        print(f"--- {a['audio']}  {a['when']}  {a['seconds']:.1f}s  "
              f"similarity {similarity((a, b)):.2f}")
        print(f"  {left:9s} {a['raw'].strip()}")
        print(f"  {right:9s} {b['raw'].strip()}")
        if a["was"] and a["was"].strip() not in (a["text"].strip(), b["text"].strip()):
            print(f"  {'you got':9s} {a['was'].strip()}")
        print()
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--collect", metavar="LABEL",
                    help="replay every retained take through the running model")
    ap.add_argument("--report", nargs=2, metavar=("LEFT", "RIGHT"),
                    help="diff two collected passes")
    args = ap.parse_args()

    if not SOCK.exists():
        print("engine is not running. start it with: phona ping")
        return 2
    if args.collect:
        return collect(args.collect)
    if args.report:
        return report(*args.report)
    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
