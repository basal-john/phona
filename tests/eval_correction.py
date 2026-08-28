"""Score the correction stage on your own dictation, hard enough to separate two models.

The grammar suite in `fixtures/grammar_cases.jsonl` is a pass or fail gate and the current
model passes 29 of 29, so it cannot rank anything. This can. It runs two axes over the
sentences you actually dictated, and reports numbers that move.

Axis one plants a known error into a clean sentence of your own and checks whether the model
removes exactly that error. Ground truth is free because the clean sentence is the answer,
and the domain is right because the sentence is yours. Every injector is the inverse of a
rule the system prompt names, and each one only fires where its pattern really occurs, so a
planted case always has a recoverable answer.

Axis two sends the raw transcripts through untouched and measures what the model did with
them: how many LanguageTool findings it cleared, how much of the wording it kept, how often
it returned the input verbatim, and how often the guard caught it. LanguageTool is optional.
Without it the axis still reports everything else.

    python tests/eval_correction.py --plant                    write the planted corpus
    python tests/eval_correction.py --run qwen3-4b-8bit        score the running model
    ./switch-model.sh 4bit
    python tests/eval_correction.py --run qwen3-4b-4bit
    python tests/eval_correction.py --report qwen3-4b-8bit qwen3-4b-4bit

Nothing reaches your history and no audio is retained, so a scoring pass leaves no trace.

LanguageTool leans on punctuation and capitalisation, which is real work the model does but
the easy half of it. Across the first 115 takes it found 69 findings before correction and
16 after, and 39 of the 69 were sentence case, commas and a lowercase "i". The counts are
therefore split into grammar and typography, and the planted axis carries the hard half.
"""

import argparse
import difflib
import json
import pathlib
import re
import socket
import time

BASE = pathlib.Path.home() / ".local/share/phona"
SOCK = BASE / "phonad.sock"
REPLAYS = pathlib.Path(__file__).resolve().parent / "replays"
OUT = pathlib.Path(__file__).resolve().parent / "evals"
PLANTED = OUT / "planted.json"

TYPOGRAPHY = {
    "UPPERCASE_SENTENCE_START",
    "I_LOWERCASE",
    "COMMA_COMPOUND_SENTENCE",
    "COMMA_COMPOUND_SENTENCE_2",
    "INTERJECTIONS_PUNCTUATION",
    "QUESTION_MARK",
    "PUNCTUATION_PARAGRAPH_END",
    "SENTENCE_WHITESPACE",
    "DOUBLE_PUNCTUATION",
    "APOSTROPHE_MISSING",
    "UNPAIRED_BRACKETS",
}

PER_KIND = 14

INJECTORS = [
    ("article_the", r"\bthe (\w+)", r"\1"),
    ("article_a", r"\ba (\w+)", r"\1"),
    ("agreement_is", r"\bis\b", "are"),
    ("agreement_are", r"\bare\b", "is"),
    ("agreement_has", r"\bhas\b", "have"),
    ("agreement_have", r"\bhave\b", "has"),
    ("tense_was", r"\bwas\b", "were"),
    ("progressive_drop", r"\b(is|are|was|were) (\w+ing)\b", r"\2"),
    ("preposition_on", r"\bon\b", "in"),
    ("preposition_to", r"\bto\b", "for"),
    ("preposition_for", r"\bfor\b", "to"),
    ("preposition_verb", r"\bworking on\b", "working"),
    ("comparative", r"\b(better|faster|smaller|larger|simpler|easier)\b", r"more \1"),
    ("plural_missing", r"\b(several|many|both|two|three|all the) (\w+)s\b", r"\1 \2"),
    ("since_for", r"\bfor (\w+) (years|months|weeks|days|hours)\b", r"since \1 \2"),
    ("copula", r"\bI (agree|disagree|think|want)\b", r"I am \1"),
    ("double_negative", r"\b(don't|do not|didn't) (\w+) any\b", r"\1 \2 no"),
]


def request(payload, timeout=600):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(str(SOCK))
    sock.sendall((json.dumps(payload) + "\n").encode())
    line = sock.makefile("r").readline()
    sock.close()
    return json.loads(line)


CONTRACTIONS = [
    (r"\b(\w+)'re\b", r"\1 are"),
    (r"\bit's\b", "it is"),
    (r"\bthat's\b", "that is"),
    (r"\bthere's\b", "there is"),
    (r"\b(\w+)'ve\b", r"\1 have"),
    (r"\b(\w+)'ll\b", r"\1 will"),
    (r"\b(can)not\b|\bcan't\b", "can not"),
    (r"\b(\w+)n't\b", r"\1 not"),
    (r"\bi'm\b", "i am"),
]


def words(text):
    """The words alone, with contractions expanded, as a list of tokens.

    Punctuation and case must not decide whether an answer is right, and neither must a
    contraction. A model that repairs "you is" to "you're" has fixed the agreement error as
    surely as one that writes "you are", and scoring the two differently measures the
    model's taste rather than its grammar.
    """
    text = (text or "").lower().replace("’", "'")
    for pattern, replacement in CONTRACTIONS:
        text = re.sub(pattern, replacement, text)
    return re.sub(r"[^a-z0-9' ]", " ", text).split()


def distance(left, right):
    """Levenshtein distance between two token lists."""
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(
                previous[j - 1] if a == b else 1 + min(previous[j - 1], previous[j], current[j - 1])
            )
        previous = current
    return previous[-1]


def sentences():
    """The corrected text of every replayed take, newest replay first, deduplicated.

    The corrected text is used rather than the raw transcript because a planted case needs a
    clean starting point. Anything the guard rejected is dropped, since its text is the raw
    transcript rather than a correction.
    """
    seen, out = set(), []
    for path in sorted(REPLAYS.glob("*.json")):
        for row in json.loads(path.read_text()).get("rows", []):
            text = (row.get("text") or "").strip()
            if not text or row.get("guarded") or len(text.split()) < 4:
                continue
            key = tuple(words(text))
            if key in seen:
                continue
            seen.add(key)
            out.append(text)
    return out


def plant(text):
    """Every planted variant of one sentence, as (kind, broken) pairs.

    A variant is kept only when it actually changed the sentence, so a rule that did not
    match contributes nothing and never produces a case whose answer is the input.
    """
    made = []
    for kind, pattern, replacement in INJECTORS:
        broken = re.sub(pattern, replacement, text, count=1)
        if broken != text:
            made.append((kind, broken))
    return made


def build_planted():
    OUT.mkdir(exist_ok=True)
    clean = sentences()
    kinds, cases = {}, []
    for text in clean:
        for kind, broken in plant(text):
            if kinds.get(kind, 0) >= PER_KIND:
                continue
            kinds[kind] = kinds.get(kind, 0) + 1
            cases.append({"kind": kind, "broken": broken, "gold": text})
    PLANTED.write_text(json.dumps(cases, indent=1) + "\n")
    print(f"wrote {PLANTED} with {len(cases)} cases from {len(clean)} sentences")
    for kind, count in sorted(kinds.items(), key=lambda kv: -kv[1]):
        print(f"  {kind:22} {count}")


def checker():
    """A LanguageTool handle, or None when it is not installed.

    The tool is a 259 MB Java download and only this script wants it, so it stays out of the
    engine's own environment and out of CI. Without it the run still produces every other
    number.
    """
    try:
        import language_tool_python
    except ImportError:
        return None
    return language_tool_python.LanguageTool("en-US")


def findings(tool, text):
    """LanguageTool findings for one string, split into grammar and typography counts."""
    if tool is None or not text:
        return 0, 0
    grammar = typography = 0
    for match in tool.check(text):
        if match.rule_id in TYPOGRAPHY:
            typography += 1
        else:
            grammar += 1
    return grammar, typography


def fix(text):
    started = time.time()
    reply = request({"cmd": "FIX", "text": text, "history": False})
    return reply, time.time() - started


def run(label):
    OUT.mkdir(exist_ok=True)
    if not SOCK.exists():
        print("engine is not running. start it with: phona ping")
        return 2
    if not PLANTED.exists():
        print(f"no planted corpus yet. run: python {pathlib.Path(__file__).name} --plant")
        return 2

    status = request({"cmd": "STATUS"})
    tool = checker()
    if tool is None:
        print("language_tool_python is not installed, skipping the findings count")

    cases = json.loads(PLANTED.read_text())
    planted = []
    for i, case in enumerate(cases, 1):
        reply, secs = fix(case["broken"])
        got = reply.get("text", "")
        got_w, gold_w, broken_w = words(got), words(case["gold"]), words(case["broken"])
        to_gold, to_broken = distance(got_w, gold_w), distance(got_w, broken_w)
        planted.append(
            {
                "kind": case["kind"],
                "broken": case["broken"],
                "gold": case["gold"],
                "got": got,
                "repaired": to_gold < to_broken,
                "clean": got_w == gold_w,
                "collateral": to_gold if to_gold < to_broken else 0,
                "untouched": got_w == broken_w,
                "similarity": difflib.SequenceMatcher(None, got_w, gold_w).ratio(),
                "guarded": bool(reply.get("guarded")),
                "guard_reason": reply.get("guard_reason"),
                "secs": round(secs, 3),
            }
        )
        if i % 25 == 0:
            print(f"  planted {i}/{len(cases)}", flush=True)

    live = []
    raws = []
    for path in sorted(REPLAYS.glob("*.json")):
        for row in json.loads(path.read_text()).get("rows", []):
            raw = (row.get("raw") or "").strip()
            if raw and len(raw.split()) >= 4:
                raws.append(raw)
    for i, raw in enumerate(raws, 1):
        reply, secs = fix(raw)
        got = reply.get("text", "")
        before = findings(tool, raw)
        after = findings(tool, got)
        got_w, raw_w = words(got), words(raw)
        live.append(
            {
                "raw": raw,
                "got": got,
                "grammar_before": before[0],
                "grammar_after": after[0],
                "typography_before": before[1],
                "typography_after": after[1],
                "kept": difflib.SequenceMatcher(None, got_w, raw_w).ratio(),
                "untouched": got_w == raw_w,
                "guarded": bool(reply.get("guarded")),
                "guard_reason": reply.get("guard_reason"),
                "secs": round(secs, 3),
            }
        )
        if i % 25 == 0:
            print(f"  live {i}/{len(raws)}", flush=True)

    out = OUT / f"{label}.json"
    out.write_text(
        json.dumps(
            {
                "label": label,
                "llm_model": status.get("llm_model"),
                "llm_revision": status.get("llm_revision"),
                "language_tool": tool is not None,
                "planted": planted,
                "live": live,
            },
            indent=1,
        )
        + "\n"
    )
    if tool is not None:
        tool.close()
    print(f"wrote {out}")
    summarise(json.loads(out.read_text()))
    return 0


def score(data):
    """The headline numbers for one run, as a dict of already-rounded values."""
    planted, live = data["planted"], data["live"]
    n = len(planted) or 1
    m = len(live) or 1
    grammar_before = sum(r["grammar_before"] for r in live)
    grammar_after = sum(r["grammar_after"] for r in live)
    typo_before = sum(r["typography_before"] for r in live)
    typo_after = sum(r["typography_after"] for r in live)
    repaired = sum(r["repaired"] for r in planted)
    return {
        "cases": len(planted),
        "repaired": repaired,
        "repaired_pct": round(100 * repaired / n, 1),
        "clean": sum(r["clean"] for r in planted),
        "clean_pct": round(100 * sum(r["clean"] for r in planted) / n, 1),
        "missed": sum(r["untouched"] for r in planted),
        "collateral": sum(r["collateral"] for r in planted),
        "near": round(sum(r["similarity"] for r in planted) / n, 3),
        "takes": len(live),
        "grammar": f"{grammar_before} -> {grammar_after}",
        "typography": f"{typo_before} -> {typo_after}",
        "kept": round(sum(r["kept"] for r in live) / m, 3),
        "untouched_pct": round(100 * sum(r["untouched"] for r in live) / m, 1),
        "guarded": sum(r["guarded"] for r in planted) + sum(r["guarded"] for r in live),
        "gave_up": sum(1 for r in live if r["guarded"] and r["untouched"])
        + sum(1 for r in planted if r["guarded"] and r["untouched"]),
        "secs": round((sum(r["secs"] for r in planted) + sum(r["secs"] for r in live)) / (n + m), 3),
    }


def reasons(data):
    """Why the guard fired, most common first.

    The reason is what the first refusal saw, so it names the shape of the failure rather
    than the sentence. A count that concentrates on one reason is a prompt problem, and a
    count spread evenly is a model problem.
    """
    counted = {}
    for row in data["planted"] + data["live"]:
        reason = row.get("guard_reason")
        if reason:
            counted[reason] = counted.get(reason, 0) + 1
    return sorted(counted.items(), key=lambda kv: -kv[1])


def summarise(data):
    s = score(data)
    print(f"\n{data['label']}  {data['llm_model']}")
    print(f"  planted   {s['repaired']}/{s['cases']} repaired ({s['repaired_pct']}%), "
          f"{s['clean']} of those with no other edit, {s['missed']} returned unchanged")
    print(f"            {s['collateral']} stray token edits, mean closeness {s['near']}")
    print(f"  findings  grammar {s['grammar']}, typography {s['typography']}"
          + ("" if data["language_tool"] else "   (LanguageTool not installed)"))
    print(f"  live      wording kept {s['kept']}, {s['untouched_pct']}% left alone, "
          f"{s['guarded']} guarded")
    print(f"  guard     {s['guarded']} needed a retry, {s['gave_up']} of those came back "
          f"with no word changed")
    for reason, count in reasons(data):
        print(f"            {count:>3}  {reason}")
    print(f"  speed     {s['secs']}s mean per correction")


def report(left, right):
    rows = []
    for label in (left, right):
        path = OUT / f"{label}.json"
        if not path.exists():
            print(f"no run named {label}, expected {path}")
            return 2
        rows.append(json.loads(path.read_text()))

    a, b = (score(r) for r in rows)
    print(f"{'':22}{left:>26}{right:>26}")
    print(f"{'model':22}{rows[0]['llm_model'][-24:]:>26}{rows[1]['llm_model'][-24:]:>26}")
    for key, name in (
        ("repaired_pct", "planted repaired %"),
        ("clean_pct", "repaired with no stray %"),
        ("missed", "planted left alone"),
        ("collateral", "stray token edits"),
        ("near", "planted closeness"),
        ("grammar", "grammar findings"),
        ("typography", "typography findings"),
        ("kept", "wording kept"),
        ("untouched_pct", "live left alone %"),
        ("guarded", "guard retries"),
        ("gave_up", "guarded, no word changed"),
        ("secs", "mean seconds"),
    ):
        print(f"{name:22}{str(a[key]):>26}{str(b[key]):>26}")

    disagreed = [
        (x, y)
        for x, y in zip(rows[0]["planted"], rows[1]["planted"])
        if x["repaired"] != y["repaired"]
    ]
    print(f"\n{len(disagreed)} planted cases where one repaired it and the other did not")
    for x, y in disagreed[:15]:
        winner = left if x["repaired"] else right
        print(f"\n--- {x['kind']}  only {winner} fixed this")
        print(f"  planted   {x['broken']}")
        print(f"  {left:9} {x['got']}")
        print(f"  {right:9} {y['got']}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plant", action="store_true", help="build the planted corpus")
    ap.add_argument("--run", metavar="LABEL", help="score the running model under this name")
    ap.add_argument("--report", nargs=2, metavar=("A", "B"), help="compare two runs")
    args = ap.parse_args()

    if args.plant:
        build_planted()
        return 0
    if args.run:
        return run(args.run)
    if args.report:
        return report(*args.report)
    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
