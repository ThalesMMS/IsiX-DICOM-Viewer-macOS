"""Run a test under a Python that has the modules it needs, or skip it.

A test that needs pydicom, numpy or a codec plugin the system python3 lacks
used to fail. It now looks for an interpreter that has them - this one, the
virtual environments in local-validation/ (see AGENTS.md), then scratchpad
ones - and re-executes itself there; with none, it exits 2, which
tools/run-tests.py reports as skipped with what to install.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def candidates():
    yield sys.executable
    for pattern in ('local-validation/*venv*/bin/python',):
        yield from (str(path) for path in sorted(ROOT.glob(pattern)))
    yield from (str(path) for path in sorted(Path('/private/tmp').glob('*/*/*/scratchpad/*venv*/bin/python')))


def interpreter(*imports):
    """The first interpreter that can run `import <each>`, or None."""
    probe = '; '.join(imports)
    for candidate in candidates():
        if subprocess.run([candidate, '-c', probe], capture_output=True).returncode == 0:
            return candidate
    return None


def require(*imports, packages="'pydicom>=3,<4' numpy"):
    """Continue under an interpreter that has `imports`, or exit as skipped."""
    probe = '; '.join(imports)
    if subprocess.run([sys.executable, '-c', probe], capture_output=True).returncode == 0:
        return
    found = interpreter(*imports)
    if found and os.path.abspath(found) != os.path.abspath(sys.executable):
        os.execv(found, [found, os.path.abspath(sys.argv[0])] + sys.argv[1:])
    print('skipped: needs a Python with %s; for example python3 -m venv local-validation/fixture-venv && '
          'local-validation/fixture-venv/bin/python -m pip install %s' % (probe, packages), file=sys.stderr)
    raise SystemExit(2)
