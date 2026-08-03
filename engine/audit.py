"""Look through the dictation log for things that went wrong, and propose fixes.

Two passes, in order of trustworthiness.

The deterministic pass reads facts the daemon already recorded: which takes were rejected,
where the guard had to reject a correction, and which entries the user flagged by hand.
These are exact, so they are reported as findings rather than guesses.

The inference pass asks the local model whether a transcript contains phrases that no one
would plausibly have said, which is how a mishearing like "cron job" becoming "con job"
gets caught. It runs on the same local model the app already uses, so a scheduled audit
does not quietly start shipping every dictation to a cloud service.

Nothing is applied. The output is a proposal, because a tool that edits its own
configuration behind the user's back is the reason these features get distrusted.

    python audit.py                 last 7 days
    python audit.py --days 30
    python audit.py --json          machine readable, for the skill
    python audit.py --apply         write the accepted replacements into config.json
"""

import argparse
import collections
import datetime as dt
import difflib
import json
import os
import pathlib
import re
import socket
import sys

BASE = pathlib.Path(os.environ.get("PHONA_HOME") or pathlib.Path.home() / ".local/share/phona")
HISTORY = BASE / "history.jsonl"
CORRECTIONS = BASE / "corrections.jsonl"
CONFIG = BASE / "config.json"
SOCK = BASE / "phonad.sock"


def read_jsonl(path):
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def within(entry, days, key="ts"):
    stamp = entry.get(key)
    if not stamp:
        return False
    try:
        when = dt.datetime.fromisoformat(stamp)
    except ValueError:
        return False
    return when >= dt.datetime.now() - dt.timedelta(days=days)


def ask_model(text, timeout=180):
    """Send one prompt through the daemon's correction endpoint is not enough here, so
    talk to it directly with a purpose-built instruction."""
    payload = {"cmd": "FIX", "text": text, "mode": "raw"}
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(str(SOCK))
        sock.sendall((json.dumps(payload) + "\n").encode())
        line = sock.makefile("r").readline()
        sock.close()
        return json.loads(line)
    except Exception:
        return None


def deterministic_findings(history, corrections):
    """Facts, not guesses. Everything here was recorded by the daemon or the user.

    Refused corrections are read from the flag the daemon writes rather than inferred from
    the text, which produced false positives on entries where the model had only punctuation
    to fix.
    """
    findings = []

    flagged = [c for c in corrections]
    for c in flagged:
        finding = {
            "kind": "flagged_by_you",
            "confidence": "certain",
            "heard": c.get("heard", ""),
            "returned": c.get("returned", ""),
            "actual": c.get("actual"),
        }
        if c.get("actual"):
            finding["suggestion"] = diff_words(c["heard"], c["actual"])
        findings.append(finding)

    rejected = [h for h in history if h.get("state") in ("silent", "garbled", "empty")]
    if rejected:
        findings.append({
            "kind": "takes_discarded",
            "confidence": "certain",
            "count": len(rejected),
            "note": "Recording produced nothing usable. Usually an idle Option hold, "
                    "but a run of these can mean the wrong input device.",
        })

    guarded = [h for h in history if h.get("guarded")]
    if guarded:
        findings.append({
            "kind": "corrections_refused",
            "confidence": "certain",
            "count": len(guarded),
            "note": "The guard rejected the model's rewrite and fell back to tidying. "
                    "Grammar in these was left alone.",
            "examples": [g.get("text", "")[:90] for g in guarded[:3]],
        })

    return findings


COMMON = {
    "con", "cron", "log", "logo", "form", "from", "there", "their", "then", "than",
    "one", "won", "to", "too", "two", "for", "four", "its", "it's", "our", "are",
    "be", "we", "he", "she", "a", "an", "the", "in", "on", "at", "is", "as", "no",
    "know", "now", "new", "knew", "right", "write", "week", "weak", "made", "maid",
}


def diff_words(heard, actual):
    """Turn a flagged pair into a concrete replacement proposal.

    Replacements fire on word boundaries across everything the user dictates, so a proposal
    like "con = cron" taken from one flagged sentence would wreck "con man". A wrong side
    that is ordinary English on its own therefore pulls in the following word to
    disambiguate it, and is dropped entirely when it cannot.
    """
    a = heard.lower().split()
    b = actual.lower().split()
    pairs = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if op != "replace" or (i2 - i1) > 3 or (j2 - j1) > 3:
            continue
        wrong_words = a[i1:i2]
        right_words = b[j1:j2]
        if any(w.strip(".,!?") in COMMON for w in wrong_words):
            if i2 < len(a) and j2 < len(b) and a[i2] == b[j2]:
                wrong_words = wrong_words + [a[i2]]
                right_words = right_words + [b[j2]]
            else:
                continue
        wrong = " ".join(wrong_words).strip(".,!?")
        right = " ".join(right_words).strip(".,!?")
        if wrong and right and wrong != right:
            pairs.append({"wrong": wrong, "right": right})
    return pairs


def inference_findings(history, limit=40):
    """Ask the local model which transcripts contain something implausible."""
    voice = [h for h in history if h.get("source") == "voice" and h.get("raw")][-limit:]
    if not voice:
        return []

    numbered = "\n".join(f"{i + 1}. {h['raw'][:220]}" for i, h in enumerate(voice))
    prompt = (
        "Below are speech-to-text transcripts. Some contain a mishearing: a real word or "
        "phrase that makes no sense in context, where the speaker clearly said something "
        "similar sounding. Examples of the pattern: 'con job' for 'cron job', 'copy "
        "vegetable' for 'copy-pasteable'.\n\n"
        "List only the lines that contain such a mishearing. For each, output one line "
        "exactly as: NUMBER | wrong phrase | most likely intended phrase\n"
        "If a line reads plausibly, do not mention it. Output nothing else.\n\n"
        + numbered
    )
    reply = ask_model(prompt)
    if not reply or not reply.get("text"):
        return []

    findings = []
    for line in reply["text"].splitlines():
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3:
            continue
        num = re.match(r"\d+", parts[0])
        if not num:
            continue
        idx = int(num.group()) - 1
        if not (0 <= idx < len(voice)):
            continue
        wrong, right = parts[1], parts[2]
        if not wrong or not right or wrong.lower() == right.lower():
            continue
        findings.append({
            "kind": "likely_mishearing",
            "confidence": "inferred",
            "heard": voice[idx]["raw"][:160],
            "suggestion": [{"wrong": wrong, "right": right}],
        })
    return findings


def collect(days):
    """Gather findings and turn them into replacement proposals.

    Proposals are limited to single words and short phrases. A longer replacement is too
    blunt an instrument and would fire on text the user never meant it to touch.
    """
    history = [h for h in read_jsonl(HISTORY) if within(h, days)]
    corrections = [c for c in read_jsonl(CORRECTIONS) if within(c, days, "flagged_at")]
    findings = deterministic_findings(history, corrections)
    findings += inference_findings(history)

    proposals = {}
    for f in findings:
        for pair in f.get("suggestion") or []:
            if len(pair["wrong"].split()) <= 3 and pair["wrong"].lower() != pair["right"].lower():
                proposals[pair["wrong"].lower()] = pair["right"]

    return {
        "window_days": days,
        "dictations": len([h for h in history if h.get("source") == "voice"]),
        "flagged_by_you": len(corrections),
        "findings": findings,
        "proposed_replacements": proposals,
    }


def apply_proposals(proposals):
    cfg = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    existing = cfg.get("replacements") or {}
    added = {k: v for k, v in proposals.items() if k not in existing}
    if not added:
        return {}
    existing.update(added)
    cfg["replacements"] = existing
    CONFIG.write_text(json.dumps(cfg, indent=2, sort_keys=True) + "\n")
    return added


def human(report):
    lines = []
    lines.append(f"Phona audit, last {report['window_days']} days")
    lines.append(f"{report['dictations']} dictations, "
                 f"{report['flagged_by_you']} flagged by you")
    lines.append("")

    if not report["findings"]:
        lines.append("Nothing worth reporting. No flags, no discarded takes, no "
                     "implausible transcripts.")
        return "\n".join(lines)

    by_kind = collections.defaultdict(list)
    for f in report["findings"]:
        by_kind[f["kind"]].append(f)

    titles = {
        "flagged_by_you": "You flagged these",
        "takes_discarded": "Recordings that produced nothing",
        "corrections_refused": "Corrections the guard refused",
        "likely_mishearing": "Possible mishearings, inferred so treat with suspicion",
    }
    for kind, items in by_kind.items():
        lines.append(f"## {titles.get(kind, kind)}")
        for f in items:
            if f.get("count") is not None:
                lines.append(f"  {f['count']} of them. {f.get('note', '')}")
                for ex in f.get("examples", []):
                    lines.append(f"    - {ex}")
            else:
                lines.append(f"  heard   : {f.get('heard', '')}")
                if f.get("actual"):
                    lines.append(f"  actually: {f['actual']}")
                for pair in f.get("suggestion") or []:
                    lines.append(f"    -> {pair['wrong']}  =  {pair['right']}")
        lines.append("")

    if report["proposed_replacements"]:
        lines.append("## Proposed replacements")
        for wrong, right in sorted(report["proposed_replacements"].items()):
            lines.append(f"  {wrong} = {right}")
        lines.append("")
        lines.append("Apply with:  python audit.py --apply")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    report = collect(args.days)

    if args.apply:
        added = apply_proposals(report["proposed_replacements"])
        if added:
            print(f"added {len(added)} replacements to config.json")
            for k, v in added.items():
                print(f"  {k} = {v}")
            print("run 'phona restart' for the engine to pick them up")
        else:
            print("nothing new to add")
        return

    print(json.dumps(report, indent=2) if args.json else human(report))


if __name__ == "__main__":
    main()
