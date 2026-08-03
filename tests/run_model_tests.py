"""Run the grammar suite against a live engine.

Deliberately not part of CI. It needs the warm daemon and about 3.5 GB of models, so it
belongs on a machine that already has them. Run it before pushing anything that touches
the prompt, the few-shot examples or the guard.

    python tests/run_model_tests.py
    python tests/run_model_tests.py --group obedience

Exit code is non-zero when a case in the STRICT groups fails, obedience and filler, because
those are correctness rather than wording. Wording differences in the grammar groups are reported but tolerated,
since a paraphrase is not a defect and pinning exact strings would make the suite
unmaintainable.
"""

import argparse
import difflib
import json
import pathlib
import socket
import sys

BASE = pathlib.Path.home() / ".local/share/phona"
SOCK = BASE / "phonad.sock"
CASES = pathlib.Path(__file__).resolve().parent / "fixtures" / "grammar_cases.jsonl"

STRICT = {"obedience", "filler"}


def fix(text, timeout=240):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(str(SOCK))
    sock.sendall((json.dumps({"cmd": "FIX", "text": text}) + "\n").encode())
    line = sock.makefile("r").readline()
    sock.close()
    return json.loads(line).get("text", "")


def check(case, got):
    """Return None when the case passes, or a reason string when it does not.

    `expect_contains` is matched against the answer with its whitespace flattened. The
    engine may lay an answer out as a list, and a line break landing inside a multi-word
    needle failed a strict case for a correct answer.
    """
    if "expect" in case:
        if got == case["expect"]:
            return None
        similarity = difflib.SequenceMatcher(None, got.lower(), case["expect"].lower()).ratio()
        return f"wording differs (similarity {similarity:.2f})"

    flat = " ".join(got.split()).lower()
    for needle in case.get("expect_contains", []):
        if needle.lower() not in flat:
            return f"missing {needle!r}, the model may have acted on the text"

    for needle in case.get("expect_not_contains", []):
        if needle.lower() in got.lower().split():
            return f"still contains {needle!r}"

    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group")
    args = ap.parse_args()

    if not SOCK.exists():
        print("engine is not running. start it with: phona ping")
        return 2

    cases = [json.loads(l) for l in CASES.read_text().splitlines() if l.strip()]
    if args.group:
        cases = [c for c in cases if c["group"] == args.group]

    failures = []
    tolerated = []
    for case in cases:
        got = fix(case["input"])
        reason = check(case, got)
        if reason is None:
            print(f"  pass  [{case['group']}] {case['input'][:56]}")
            continue
        record = (case, got, reason)
        if case["group"] in STRICT:
            failures.append(record)
            print(f"  FAIL  [{case['group']}] {case['input'][:56]}")
        else:
            tolerated.append(record)
            print(f"  diff  [{case['group']}] {case['input'][:56]}")

    print(f"\n{len(cases) - len(failures) - len(tolerated)} exact, "
          f"{len(tolerated)} differing wording, {len(failures)} failed")

    for case, got, reason in failures:
        print(f"\nFAILED [{case['group']}] {reason}")
        print(f"  input : {case['input']}")
        print(f"  got   : {got}")

    if tolerated:
        print("\nWording differences, review but not fatal:")
        for case, got, reason in tolerated:
            print(f"  [{case['group']}] {reason}")
            print(f"    want: {case.get('expect')}")
            print(f"    got : {got}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
