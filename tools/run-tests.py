#!/usr/bin/env python3
"""Run the focused tests in tests/ and report pass, fail and skip.

Some tests need something this repository does not carry: a built helper from
`build/`, a synthetic DICOM fixture, an adapted external plugin source, or the
built application bundle. Those exit 2 and are reported as skipped with the
argument they wanted, so a sweep of the suite says what was not exercised
instead of burying it among failures.

An opt-in --inputs-manifest supplies positional arguments and environment values
per test: {"tests": {"test-dcm-host-services.py": {"args": ["PRODUCTS_DIR"],
"env": {"HOROS_TEST_CONFIGURATION": "Debug"}}}}. Keep machine-specific paths
in an ignored local manifest; absent entries retain the usual no-argument run.
--jobs N only runs entries marked "parallel_safe": true concurrently. Mark only
independent tests with private temporary workspaces; benchmarks, native/AppKit
checks and nested builds are conservatively forced into the serial lane.
Shared-artifact writers must stay unmarked. Serial
entries wait for all preceding parallel work to finish. --check-temp is serial.

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
import concurrent.futures
import json
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


def run_test(test, check_temp, inputs=None):
    """Runs one test. With check_temp, also returns what it left in its own
    TMPDIR and what appeared meanwhile in the user's temporary folder."""
    inputs = inputs or {}
    command = [sys.executable, str(test), *inputs.get("args", [])]
    environment = dict(os.environ, **inputs.get("env", {}))
    if not check_temp:
        return subprocess.run(command, capture_output=True, text=True, cwd=ROOT, env=environment), [], []
    shared = user_temp_dir()
    own = Path(tempfile.mkdtemp(prefix="run-tests-", dir=shared))
    environment["TMPDIR"] = f"{own}/"
    before = listing(shared)
    try:
        result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT,
                                env=environment)
        left = [f"$TMPDIR/{name}" for name in sorted(listing(own))]
        # Another checked run's own folders are not this test's leftovers.
        appeared = [shared / name for name in sorted(listing(shared) - before) if not name.startswith("run-tests-")]
    finally:
        shutil.rmtree(own, ignore_errors=True)
    return result, left, appeared


def serial_required(test):
    """Conservative barriers for benchmarks, native/AppKit probes and nested builds."""
    if "native" in test.name or "benchmark" in test.name:
        return True
    source = test.read_text(errors="replace")
    return any(marker in source for marker in ("NSApplication", "AppKit", "Cocoa",
                                               "swift_dylib", "cmake", "xcodebuild"))


def scheduled_tests(tests, check_temp, inputs, jobs):
    """Consecutive explicitly independent tests share a pool; serial barriers drain it."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        pending = []
        for test in tests:
            entry = inputs.get(test.name, {})
            if jobs > 1 and entry.get("parallel_safe", False) and not serial_required(test):
                pending.append((test, pool.submit(run_test, test, check_temp, entry)))
                continue
            for queued, future in pending:
                yield queued, future.result()
            pending.clear()
            yield test, run_test(test, check_temp, entry)
        for queued, future in pending:
            yield queued, future.result()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pattern", nargs="?", default="test-*.py",
                        help="glob within tests/, e.g. 'test-dicom-*.py'")
    parser.add_argument("--verbose", action="store_true",
                        help="print each test as it finishes")
    parser.add_argument("--check-temp", action="store_true",
                        help="fail tests that leave anything in TMPDIR or the user's temporary folder")
    parser.add_argument("--inputs-manifest", type=Path,
                        help="opt-in JSON: {\"tests\": {\"test-name.py\": {\"args\": [...], \"env\": {...}}}}; defaults stay unchanged")
    parser.add_argument("--jobs", type=int, default=1,
                        help="parallel workers for manifest entries explicitly marked parallel_safe; all others remain serial")
    arguments = parser.parse_args()
    if arguments.jobs < 1:
        parser.error("--jobs must be positive")
    if arguments.check_temp and arguments.jobs != 1:
        parser.error("--check-temp requires --jobs 1 because shared temporary-folder attribution is serial")
    inputs = {}
    if arguments.inputs_manifest:
        try:
            inputs = json.loads(arguments.inputs_manifest.read_text())["tests"]
            if not isinstance(inputs, dict):
                raise ValueError("tests must be an object")
            for name, entry in inputs.items():
                if Path(name).name != name or not (ROOT / "tests" / name).is_file():
                    raise ValueError(f"unknown test: {name}")
                if not isinstance(entry, dict) or set(entry) - {"args", "env", "parallel_safe"}:
                    raise ValueError(f"invalid fields for {name}")
                if not isinstance(entry.get("args", []), list) or not all(isinstance(value, str) and "\0" not in value for value in entry.get("args", [])):
                    raise ValueError(f"args must be strings for {name}")
                if not isinstance(entry.get("parallel_safe", False), bool):
                    raise ValueError(f"parallel_safe must be boolean for {name}")
                environment = entry.get("env", {})
                if not isinstance(environment, dict) or not all(isinstance(key, str) and bool(key) and isinstance(value, str) and "=" not in key and "\0" not in key + value for key, value in environment.items()):
                    raise ValueError(f"env must map valid names to strings for {name}")
        except (OSError, ValueError, KeyError, TypeError) as error:
            parser.error(f"invalid inputs manifest: {error}")

    if arguments.check_temp:
        # Stopped with kill, the run still removes its own TMPDIR and the test.
        signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(128 + number))
    tests = sorted((ROOT / "tests").glob(arguments.pattern))
    if not tests:
        raise SystemExit(f"no tests match {arguments.pattern}")

    passed, failed, skipped, leaked = [], [], [], []
    started = time.monotonic()
    appeared = []
    for test, (result, left, new) in scheduled_tests(tests, arguments.check_temp, inputs, arguments.jobs):
        if left:
            leaked.append((test.name, left))
        appeared += [(test.name, path) for path in new]
        if result.returncode == 0:
            passed.append(test.name)
            state = "pass"
        elif result.returncode == SKIPPED:
            skipped.append((test.name, (result.stderr.strip() or result.stdout.strip()).splitlines()[-1]
                            if (result.stderr.strip() or result.stdout.strip()) else "missing prerequisite (exit 2)"))
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
