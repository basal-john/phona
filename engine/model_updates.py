"""Notice when the pinned weights have fallen behind the hub, without acting on it.

Phona pins each model to the snapshot it has already cached, so a restart cannot silently
swap the weights out from under a dictation. That is the right default and it has one
cost: nothing ever tells you a newer revision exists. This module is that missing half.

Detection only. Nothing here downloads weights, edits a config or restarts anything, because
an update that arrives on its own is exactly what the pinning was built to prevent. It
reports, and `phona update-models` stays the only thing that acts.

Two questions get confused here and only the first one is answerable this way:

- has this repo moved, meaning a new commit on the same model. That is what `check` answers.
- does a better model exist, meaning a different repo entirely. No amount of polling the
  repos already in config.json will ever surface that one, and `tests/run_model_tests.py`
  is what settles it.

One HTTPS GET per repo against huggingface.co, no weights and no token. It is the only
outbound call Phona makes outside an explicit install or update, which is why it is a
setting rather than a certainty. Every failure path returns a state rather than raising:
a laptop on a plane must print "offline" and carry on, never stall the audit that called it.
"""

import os
import pathlib

HF_CACHE = pathlib.Path(
    os.environ.get("HF_HOME") or pathlib.Path.home() / ".cache/huggingface") / "hub"

DEFAULT_TIMEOUT = 10.0


def cache_slug(repo):
    return "models--" + repo.replace("/", "--")


def local_revision(repo):
    """The commit currently cached for a hub repo.

    Deliberately reads the cache directly rather than asking the daemon, so the check works
    with the engine stopped and reports what the next start would pin to.
    """
    try:
        return (HF_CACHE / cache_slug(repo) / "refs/main").read_text().strip()
    except Exception:
        return None


def remote_revision(repo, timeout=DEFAULT_TIMEOUT):
    """The commit the hub currently serves.

    Returns a `(sha, last_modified, error)` triple. A repo that does not exist is told apart
    from a hub that could not be reached, because config.json is edited by hand and a typo in
    a model name would otherwise be reported for weeks as a network problem.
    """
    try:
        from huggingface_hub import HfApi
        from huggingface_hub.errors import RepositoryNotFoundError
    except Exception:
        return None, None, "unreachable"
    try:
        info = HfApi().model_info(repo, timeout=timeout)
        return info.sha, getattr(info, "lastModified", None), None
    except RepositoryNotFoundError:
        return None, None, "missing"
    except Exception:
        return None, None, "unreachable"


def check(repos, timeout=DEFAULT_TIMEOUT):
    """Compare each repo's cached commit against the hub's.

    States are deliberately separate rather than a bool, because "behind" and "could not
    ask" want different reactions and a check that reports them the same way is worse than
    no check at all.
    """
    out = []
    for repo in repos:
        if not repo:
            continue
        local = local_revision(repo)
        remote, modified, error = remote_revision(repo, timeout=timeout)
        if remote is None:
            state = error or "unreachable"
        elif local is None:
            state = "not cached"
        elif local == remote:
            state = "current"
        else:
            state = "behind"
        out.append({
            "repo": repo,
            "local": local,
            "remote": remote,
            "last_modified": str(modified) if modified else None,
            "state": state,
        })
    return out


def summary(results):
    """One line per repo, short shas, for a terminal or the weekly audit."""
    lines = []
    for r in results:
        local = (r["local"] or "not cached")[:12]
        if r["state"] == "current":
            lines.append(f"{r['repo']} is current at {local}")
        elif r["state"] == "behind":
            lines.append(f"{r['repo']} is behind: pinned {local}, "
                         f"hub has {(r['remote'] or '')[:12]}"
                         + (f", changed {r['last_modified'][:10]}" if r["last_modified"] else ""))
        elif r["state"] == "not cached":
            lines.append(f"{r['repo']} is not cached yet")
        elif r["state"] == "missing":
            lines.append(f"{r['repo']} does not exist on the hub, check the name in config.json")
        else:
            lines.append(f"{r['repo']} could not be checked, the hub was unreachable")
    return lines
