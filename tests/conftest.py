"""Point the engine modules at a throwaway directory before they are imported.

`phonad` reads `PHONA_HOME` once, at import, to decide where its log, config, history and
audio live. `test_logic.py` imports it at module scope, so without this the whole suite runs
against the real installation and every `log()` call in a tested code path is appended to the
daemon log a running Phona is still writing to.

That is not hypothetical. A crash investigation on 2026-09-15 read `phonad.log` to work out
when the daemon had been idle, and found 392 lines written by test runs, including
"The tests are failing." and a stack of `pytest-of-basalona` temporary paths. The log is the
only record of what the daemon did, and a test suite that writes to it makes the log lie
about the times a test happened to run.

An autouse fixture would be too late. The environment has to be set before pytest imports
the test module, which is what a conftest at collection time gives us.
"""

import os
import tempfile

_SANDBOX = tempfile.mkdtemp(prefix="phona-tests-")
os.environ["PHONA_HOME"] = _SANDBOX
