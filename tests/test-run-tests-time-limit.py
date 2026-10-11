#!/usr/bin/env python3
"""The focused-test runner stops a test that exceeds its time limit.

A copy of tools/run-tests.py runs make-believe tests in a folder of its own:
one that never ends, one that leaves a child holding its output open, and
ordinary passing, failing and skipped ones. The runner must stop the first two
with everything they started, say which timed out and what it had written, and
go on; a manifest entry's limit replaces --timeout; a run in which nothing
exceeds its limit reads as it always did.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

ROOT = Path(__file__).resolve().parents[1]

ENDLESS = '''import time
print("endless: before the wait", flush=True)
time.sleep(600)
'''
# The child inherits stdout and stderr and outlives a parent that is only killed itself.
CHILD = '''import subprocess, sys, time
from pathlib import Path
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
Path(sys.argv[1]).write_text(str(child.pid))
print("child: started", flush=True)
time.sleep(600)
'''
SLOW = 'import time\ntime.sleep(3)\n'
PASSING = 'print("fine")\n'
FAILING = 'import sys\nprint("FAIL: expected")\nsys.exit(1)\n'
SKIPPED = 'import sys\nprint("skipped: wants a fixture")\nsys.exit(2)\n'


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def run(root, *arguments):
    started = time.monotonic()
    result = subprocess.run([sys.executable, str(root / "tools/run-tests.py"), *arguments],
                            capture_output=True, text=True, timeout=120)
    return result, time.monotonic() - started


def main():
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        (root / "tools").mkdir()
        (root / "tests").mkdir()
        shutil.copy(ROOT / "tools/run-tests.py", root / "tools/run-tests.py")
        tests = root / "tests"
        (tests / "test-a-endless.py").write_text(ENDLESS)
        (tests / "test-b-child.py").write_text(CHILD)
        (tests / "test-c-slow.py").write_text(SLOW)
        (tests / "test-d-pass.py").write_text(PASSING)
        (tests / "test-e-fail.py").write_text(FAILING)
        (tests / "test-f-skip.py").write_text(SKIPPED)
        pid_file = root / "child.pid"
        manifest = root / "inputs.json"

        # Nothing exceeds its limit: the report is the one the runner always gave.
        result, _ = run(root, "test-[def]-*.py", "--verbose")
        check(result.returncode == 1, f"a failing test did not fail the run: {result.returncode}")
        for expected in ("pass  test-d-pass.py", "FAIL  test-e-fail.py", "skip  test-f-skip.py",
                         "--- test-e-fail.py ---\nFAIL: expected",
                         "test-f-skip.py: skipped: wants a fixture",
                         "\n1 passed, 1 failed, 1 skipped in "):
            check(expected in result.stdout, f"missing {expected!r} in:\n{result.stdout}")
        check("timed out" not in result.stdout, "a run without a timeout mentions one")
        result, _ = run(root, "test-d-*.py")
        check(result.returncode == 0 and "1 passed, 0 failed, 0 skipped" in result.stdout,
              f"a passing run changed:\n{result.stdout}")

        # A test that never ends is stopped, named, quoted, and the run goes on.
        result, took = run(root, "test-[ad]-*.py", "--timeout", "2")
        check(took < 30, f"the endless test held the run for {took:.0f}s")
        check(result.returncode == 1, "a timed-out test did not fail the run")
        for expected in ("TIME  test-a-endless.py  (stopped after 2s)",
                         "--- test-a-endless.py --- timed out after 2s",
                         "endless: before the wait",
                         "1 passed, 0 failed, 1 timed out, 0 skipped"):
            check(expected in result.stdout, f"missing {expected!r} in:\n{result.stdout}")

        # A child that keeps the output open neither holds the run nor survives it.
        manifest.write_text(json.dumps({"tests": {"test-b-child.py": {"args": [str(pid_file)]}}}))
        result, took = run(root, "test-[bd]-*.py", "--timeout", "2", "--inputs-manifest", str(manifest))
        check(took < 30, f"the child's open output held the run for {took:.0f}s")
        check("TIME  test-b-child.py" in result.stdout and "child: started" in result.stdout
              and "1 passed, 0 failed, 1 timed out" in result.stdout, f"unexpected report:\n{result.stdout}")
        child = int(pid_file.read_text())
        for _ in range(50):
            if not alive(child):
                break
            time.sleep(0.1)
        check(not alive(child), "the child of a timed-out test is still running")

        # The entry's limit replaces --timeout, in both directions.
        manifest.write_text(json.dumps({"tests": {"test-c-slow.py": {"timeout": 60}}}))
        result, _ = run(root, "test-c-*.py", "--timeout", "1", "--inputs-manifest", str(manifest))
        check(result.returncode == 0 and "1 passed" in result.stdout,
              f"the entry's longer limit was not used:\n{result.stdout}")
        manifest.write_text(json.dumps({"tests": {"test-c-slow.py": {"timeout": 1}}}))
        result, _ = run(root, "test-c-*.py", "--inputs-manifest", str(manifest))
        check(result.returncode == 1 and "TIME  test-c-slow.py  (stopped after 1s)" in result.stdout,
              f"the entry's shorter limit was not used:\n{result.stdout}")
        result, _ = run(root, "test-c-*.py", "--timeout", "1")
        check(result.returncode == 1 and "1 timed out" in result.stdout, "--timeout alone was not used")
        result, _ = run(root, "test-c-*.py", "--timeout", "0")
        check(result.returncode == 0, "--timeout 0 still limited the test")

        # A limit that is not a positive number is refused like any other bad field.
        for bad in ("soon", 0, -3, True):
            manifest.write_text(json.dumps({"tests": {"test-c-slow.py": {"timeout": bad}}}))
            result, _ = run(root, "test-d-*.py", "--inputs-manifest", str(manifest))
            check(result.returncode == 2 and "timeout must be a positive number of seconds" in result.stderr,
                  f"timeout {bad!r} was accepted:\n{result.stderr}")
        result, _ = run(root, "test-d-*.py", "--timeout", "-1")
        check(result.returncode == 2, "a negative --timeout was accepted")

        # With --check-temp a stopped test's own TMPDIR is still removed.
        shared = Path(subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip())
        before = {entry.name for entry in shared.iterdir() if entry.name.startswith("run-tests-")}
        result, _ = run(root, "test-a-*.py", "--timeout", "1", "--check-temp")
        after = {entry.name for entry in shared.iterdir() if entry.name.startswith("run-tests-")}
        check(result.returncode == 1 and "1 timed out" in result.stdout, f"unexpected report:\n{result.stdout}")
        check(after <= before, f"a stopped test's TMPDIR was left: {sorted(after - before)}")

    print("ok")


if __name__ == "__main__":
    main()
