"""Run a test under a Python that has the modules it needs, or skip it.

A test that needs pydicom, numpy or a codec plugin the system python3 lacks
used to fail. It now looks for an interpreter that has them - the one
HOROS_PYTHON names, this one, the virtual environments in local-validation/
and local-validation/work/ (see AGENTS.md), then scratchpad ones - and
re-executes itself there or runs its generators with it; with none, it exits
2, which tools/run-tests.py reports as skipped with what to install.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENVS = ('local-validation/*venv*/bin/python', 'local-validation/work/*venv*/bin/python')


def checkouts():
    """This checkout and, from a linked worktree, the checkout it was made from:
    Git ignores local-validation/, so a worktree has none of its own."""
    yield ROOT
    common = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True).stdout.strip()
    if common and Path(common).name == '.git' and Path(common).resolve().parent != ROOT:
        yield Path(common).resolve().parent


def candidates():
    named = os.environ.get('HOROS_PYTHON')
    if named:
        yield named
    yield sys.executable
    for checkout in checkouts():
        for pattern in VENVS:
            yield from (str(path) for path in sorted(checkout.glob(pattern)))
    yield from (str(path) for path in sorted(Path('/private/tmp').glob('*/*/*/scratchpad/*venv*/bin/python')))


def has(candidate, probe):
    try:
        return subprocess.run([candidate, '-c', probe], capture_output=True).returncode == 0
    except OSError:
        return False


def interpreter(*imports):
    """The first interpreter that can run `import <each>`, or None."""
    probe = '; '.join(imports)
    tried = set()
    for candidate in candidates():
        # A venv's python is a link to the one it was made from: the folder tells them apart.
        place = (os.path.realpath(os.path.dirname(candidate)), os.path.basename(candidate))
        if place not in tried and has(candidate, probe):
            return candidate
        tried.add(place)
    return None


def install_hint(packages="'pydicom>=3,<4' numpy"):
    return ('python3 -m venv local-validation/fixture-venv && '
            'local-validation/fixture-venv/bin/python -m pip install %s' % packages)


def interpreter_or_skip(*imports, need='needs', packages="'pydicom>=3,<4' numpy"):
    """interpreter(), for a test that runs something else with it; with none, exit as skipped."""
    found = interpreter(*imports)
    if found is None:
        print('skipped: %s a Python with %s; name one in HOROS_PYTHON, or for example %s'
              % (need, '; '.join(imports), install_hint(packages)), file=sys.stderr)
        raise SystemExit(2)
    return found


def require(*imports, packages="'pydicom>=3,<4' numpy"):
    """Continue under an interpreter that has `imports`, or exit as skipped."""
    probe = '; '.join(imports)
    if has(sys.executable, probe):
        return
    found = interpreter(*imports)
    if found and os.path.abspath(found) != os.path.abspath(sys.executable):
        os.execv(found, [found, os.path.abspath(sys.argv[0])] + sys.argv[1:])
    print('skipped: needs a Python with %s; for example %s' % (probe, install_hint(packages)), file=sys.stderr)
    raise SystemExit(2)


def prefer(*imports):
    """Continue under an interpreter that has `imports` when there is one.

    Unlike require(), finding none is not a skip here: the test goes on under
    this interpreter and skips, itself, only the part that needs them.
    """
    probe = '; '.join(imports)
    if has(sys.executable, probe):
        return
    found = interpreter(*imports)
    if found and os.path.abspath(found) != os.path.abspath(sys.executable):
        os.execv(found, [found, os.path.abspath(sys.argv[0])] + sys.argv[1:])
