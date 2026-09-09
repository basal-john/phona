"""The read side of the history's rotation.

`phonad.rotate_history` moves a full `history.jsonl` aside to `history.jsonl.<n>` and never
overwrites one, so the whole record is `.1` through `.N` in archive order followed by the
live file. Anything that reports on the record has to read all of them.

The app's window already does, through `HistoryParser.archivePaths`. The two command line
readers did not: they opened the live file alone, so from the first rotation onward
`phona history` would have shown only the tail of the record, `phona history --export`
would have written a partial export while printing a confident count, and `phona audit`
would have drawn its findings from whatever happened to be left. None of them would have
said anything was missing.
"""

import json

LIVE_NAME = "history.jsonl"


def paths(base, name=LIVE_NAME):
    """Every history file under `base`, oldest first, ending with the live one.

    Archives are ordered by the number they carry rather than by their name, because as
    strings `.10` sorts between `.1` and `.2`, which would hand back a decade of history
    shuffled. A name whose tail is not a plain number is not an archive and is left alone,
    so a `history.jsonl.bak` someone made by hand cannot enter the record.
    """
    archives = []
    for entry in base.glob(name + ".*"):
        tail = entry.name[len(name) + 1:]
        if tail.isdigit():
            archives.append((int(tail), entry))
    ordered = [entry for _, entry in sorted(archives)]
    live = base / name
    if live.exists():
        ordered.append(live)
    return ordered


def read(base, name=LIVE_NAME):
    """Every history row under `base`, in the order it was written.

    A line that will not parse is skipped rather than costing the rest of the file it sits
    in, and a file that will not open is skipped rather than costing the archives after it.
    """
    rows = []
    for path in paths(base, name):
        try:
            text = path.read_text()
        except OSError:
            continue
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows
