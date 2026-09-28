#!/usr/bin/env python3
"""Run the focused tests in tests/ and report pass, fail and skip.

Some tests need something this repository does not carry: a built helper from
`build/`, a synthetic DICOM fixture, an adapted external plugin source, or the
built application bundle. Those exit 2 and are reported as skipped with the
argument they wanted, so a sweep of the suite says what was not exercised
instead of burying it among failures.

`--check-temp` also proves the tests clean up after themselves (#803). Each
test gets a TMPDIR of its own, which must be empty when the test exits, and
the user's temporary folder (`getconf DARWIN_USER_TEMP_DIR`, where
NSTemporaryDirectory() writes whatever TMPDIR says) must hold no new entry
that is still there when the run ends. A test that leaves anything is
reported as leaking and fails the run; the checker removes its own TMPDIR
folders but nothing else. Another process that leaves something in the
temporary folder meanwhile is blamed on the test that was running, so read
the names before believing a leak there; one in $TMPDIR is certain.
"""
import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIPPED = 2

# Keep the last twelve lines for context, but surface assertion text that a
# crash stack would otherwise push off the excerpt (see #391).
_FAILURE_MARKS = ("FAIL:", "failed:", "Assertion failure",
                  "uncaught exception", "reason:")


def failure_excerpt(out, err, tail=12):
    lines = (out + err).strip().splitlines()
    interesting = [line for line in lines if any(mark in line for mark in _FAILURE_MARKS)]
    excerpt = list(dict.fromkeys(interesting + lines[-tail:]))
    return "\n".join(excerpt)


# A long abort stack must not hide the assertion that actually failed (#391).
assert "FAIL: count >= floor(expected)-1" in failure_excerpt(
    "", "FAIL: count >= floor(expected)-1\n" + "\n".join(f"frame {i}" for i in range(20)))


def user_temp_dir():
    # NSTemporaryDirectory() and FileManager ignore TMPDIR and ask confstr, so
    # the folder is compared directly, not through tempfile.gettempdir().
    found = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    return Path(found or tempfile.gettempdir())


def listing(folder):
    try:
        return set(os.listdir(folder))
    except OSError:
        return set()


def run_test(test, check_temp):
    """Runs one test. With check_temp, also returns what it left in its own
    TMPDIR and what appeared meanwhile in the user's temporary folder."""
    if not check_temp:
        return subprocess.run([sys.executable, str(test)], capture_output=True, text=True, cwd=ROOT), [], []
    shared = user_temp_dir()
    own = Path(tempfile.mkdtemp(prefix="run-tests-", dir=shared))
    environment = dict(os.environ, TMPDIR=f"{own}/")
    before = listing(shared)
    try:
        result = subprocess.run([sys.executable, str(test)], capture_output=True, text=True, cwd=ROOT,
                                env=environment)
        left = [f"$TMPDIR/{name}" for name in sorted(listing(own))]
        # Another checked run's own folders are not this test's leftovers.
        appeared = [shared / name for name in sorted(listing(shared) - before) if not name.startswith("run-tests-")]
    finally:
        shutil.rmtree(own, ignore_errors=True)
    return result, left, appeared


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pattern", nargs="?", default="test-*.py",
                        help="glob within tests/, e.g. 'test-dicom-*.py'")
    parser.add_argument("--verbose", action="store_true",
                        help="print each test as it finishes")
    parser.add_argument("--check-temp", action="store_true",
                        help="fail tests that leave anything in TMPDIR or the user's temporary folder")
    arguments = parser.parse_args()

    if arguments.check_temp:
        # Stopped with kill, the run still removes its own TMPDIR and the test.
        signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(128 + number))
    tests = sorted((ROOT / "tests").glob(arguments.pattern))
    if not tests:
        raise SystemExit(f"no tests match {arguments.pattern}")

    passed, failed, skipped, leaked = [], [], [], []
    started = time.monotonic()
    appeared = []
    for test in tests:
        result, left, new = run_test(test, arguments.check_temp)
        if left:
            leaked.append((test.name, left))
        appeared += [(test.name, path) for path in new]
        if result.returncode == 0:
            passed.append(test.name)
            state = "pass"
        elif result.returncode == SKIPPED:
            skipped.append((test.name, result.stderr.strip().splitlines()[-1]
                            if result.stderr.strip() else ""))
            state = "skip"
        else:
            failed.append((test.name, result.stdout, result.stderr))
            state = "FAIL"
        if arguments.verbose or state == "FAIL" or left:
            print(f"{state:>4}  {test.name}" + ("  (left temporary files)" if left else ""), flush=True)
        if arguments.verbose and left:
            print("".join(f"        {entry}\n" for entry in left), end="", flush=True)
    # Compilers and other processes keep short-lived files in the shared folder;
    # only what is still there once the whole run is over counts.
    stayed = {}
    for name, path in appeared:
        if path.exists() or path.is_symlink():
            stayed.setdefault(name, []).append(str(path))
    leaked = [(name, left + stayed.pop(name, [])) for name, left in leaked] + list(stayed.items())

    for name, out, err in failed:
        print(f"\n--- {name} ---")
        print(failure_excerpt(out, err))
    if skipped:
        print("\nskipped, needing input this repository does not carry:")
        for name, why in skipped:
            print(f"  {name}: {why}")
    if leaked:
        print("\nleft in the temporary folder:")
        for name, left in leaked:
            print(f"  {name}:")
            for entry in left:
                print(f"    {entry}")
    print(f"\n{len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped"
          + (f", {len(leaked)} left temporary files" if arguments.check_temp else "")
          + f" in {time.monotonic() - started:.0f}s")
    return 1 if failed or leaked else 0


if __name__ == "__main__":
    raise SystemExit(main())
