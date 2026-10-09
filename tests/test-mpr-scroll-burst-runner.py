#!/usr/bin/env python3
"""Incomplete native MPR runs fail instead of being reported as validation success.

The runner's CLI, orchestration and command-file protocol execute normally;
only the app, fixture generation, signing and screen capture are substituted.
No application, GPU, DICOM dependency or screen recording permission is needed.
"""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mpr_scroll_runner", ROOT / "tools/exercise-native-mpr-scroll-burst.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
UNSET = object()
FRAME = {"x": 0, "y": 0, "width": 100, "height": 100}
STATE = {"ok": True, "now_ms": 1000, "low_lod": False, "views": [
    {"width": 8, "height": 8, "central_mean": 40, "draws": 1, "since_last_draw_ms": 1,
     "needs_display": False, "hidden": False, "window_visible": True, "frame": FRAME}
    for _ in range(3)]}
CAPTURE = {kind: {"at": 1, "mean": 100} for kind in ("window", "display")}


def complete_burst(events):
    return {"ok": True, "events": [[index, 1, 1.5 if index % 2 == 0 else -1.5]
                                   for index in range(events)], "start_ms": 900, "end_ms": 1000}


# One reconstruction of view 1 inside the burst, then the finishing pass over the three views.
RESLICES = [[1, 950, 5], [2, 1300, 4], [3, 1305, 4], [1, 1310, 6]]


def ready(predicate, *args, **kwargs):
    value = predicate()
    if not value:
        raise TimeoutError("the substituted app did not answer")
    return value


class RunnerTests(unittest.TestCase):
    def run_main(self, *, burst=UNSET, state_fault=UNSET, state_number=1,
                 capture=UNSET, died=False, extra=(), reslices=UNSET):
        sessions = []

        class FakeSession:
            def __init__(self, app, root, dylib, log, cubic="default"):
                self.root = root
                self.cubic = cubic
                self.bursts = []
                self.stopped = False
                self.state_calls = 0
                self.exit_code = None
                self.process = SimpleNamespace(poll=lambda: self.exit_code)
                (root / "IsiX Data" / "INCOMING.noindex").mkdir(parents=True)
                sessions.append(self)

            def command(self, payload, timeout=300):
                action = payload["action"]
                if action == "ping":
                    return {"ok": True}
                if action == "open":
                    return {"ok": True, "metal": True, "window": 1, "backing_scale": 1,
                            "frames": [FRAME] * 3}
                if action == "reslices":
                    log = RESLICES if reslices is UNSET else reslices
                    return {"ok": True, "now_ms": 2000, "reslices": copy.deepcopy(log)}
                if action == "state":
                    self.state_calls += 1
                    value = state_fault if self.state_calls == state_number and state_fault is not UNSET else STATE
                    return copy.deepcopy(value)
                raise AssertionError(f"unexpected command: {action}")

            def send(self, payload):
                self.bursts.append(payload)
                answer = self.root / "burst.out.json"
                if died:
                    self.exit_code = 17
                else:
                    value = complete_burst(payload["events"]) if burst is UNSET else burst
                    answer.write_text(json.dumps(value))
                return answer

            def stop(self):
                self.stopped = True

        def phantom(folder, size, slices):
            folder.mkdir(parents=True)
            for index in range(slices):
                (folder / f"{index}.dcm").write_bytes(b"substituted fixture")
            return "synthetic-series"

        with tempfile.TemporaryDirectory(prefix="mpr-scroll-runner-") as temporary, contextlib.ExitStack() as stack:
            out = Path(temporary) / "local-validation" / "run"
            argv = [str(ROOT / "tools/exercise-native-mpr-scroll-burst.py"), "--out", str(out),
                    "--app", str(Path(temporary) / "Test.app"), "--batches", "1", "--events", "4",
                    "--size", "8", "--slices", "3", "--after-ms", "0", *extra]
            for owner, name, replacement in [
                (runner, "Session", FakeSession), (runner, "phantom", phantom),
                (runner, "prepare", lambda app, destination: destination / "probe.dylib"),
                (runner, "window_bounds", lambda window: [0, 0, 100, 100]),
                (runner, "capture", lambda *args: copy.deepcopy(CAPTURE if capture is UNSET else capture)),
                (runner.native_app, "wait_for", ready), (runner.native_app, "image_count", lambda root: 3),
                (runner.time, "sleep", lambda seconds: None),
            ]:
                stack.enter_context(patch.object(owner, name, replacement))
            stack.enter_context(patch.object(sys, "argv", argv))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            result = runner.main()
            summary = json.loads((out / "summary.json").read_text())
            return result, summary, sessions

    def assert_failed(self, **fault):
        result, summary, sessions = self.run_main(**fault)
        self.assertEqual(result, 1)
        self.assertEqual(summary["status"], "failed")
        self.assertTrue(sessions)
        self.assertTrue(all(session.stopped for session in sessions))

    def test_complete_run_is_one_metal_execution(self):
        result, summary, sessions = self.run_main()
        self.assertEqual(result, 0)
        self.assertEqual(summary["status"], "complete")
        self.assertEqual(set(summary["controls"]), {"metal"})
        self.assertEqual(len(sessions), 1)
        self.assertTrue(sessions[0].stopped)
        self.assertEqual(sessions[0].state_calls, 2)

    def test_reconstructions_are_split_between_the_burst_and_the_finishing_pass(self):
        result, summary, sessions = self.run_main(extra=("--kind", "drag", "--cubic", "on"))
        self.assertEqual(result, 0)
        self.assertEqual(sessions[0].cubic, "on")
        self.assertEqual(sessions[0].bursts[0]["kind"], "drag")
        timing = summary["timing"][0]
        self.assertEqual(timing["burst_reslices"], [1, 0, 0])
        self.assertEqual(timing["finishing_reslices"], [1, 1, 1])
        self.assertEqual(timing["finishing_reslice_ms"], 14)
        self.assertEqual(timing["settle_ms"], 55)
        self.assertEqual(timing["burst_ms"], 100)
        self.assertEqual(timing["handler_p50_ms"], 1)
        self.assertEqual(timing["lag_max_ms"], 3)

    def test_wheel_without_cubic_option_keeps_the_settings(self):
        result, summary, sessions = self.run_main()
        self.assertEqual(result, 0)
        self.assertEqual(sessions[0].cubic, "default")
        self.assertEqual(sessions[0].bursts[0]["kind"], "wheel")

    def test_invalid_reconstruction_logs_fail(self):
        for value in (None, [[1, 950]], [[1, 950, -1]], [[1, float("nan"), 2]]):
            with self.subTest(value=value):
                self.assert_failed(reslices=value)

    def test_vtk_is_rejected_before_starting_the_app(self):
        with self.assertRaises(SystemExit) as rejected:
            self.run_main(extra=("--control", "vtk"))
        self.assertEqual(rejected.exception.code, 2)

    def test_invalid_burst_arguments_are_rejected_before_native_work(self):
        cases = [("--events", "10001"), ("--delta", "0"), ("--delta", "-1"),
                 ("--delta", "2147483648"), ("--delta", "nan"), ("--delta", "inf"),
                 ("--interval-ms", "-1"), ("--events", "2", "--interval-ms", "300000")]
        with tempfile.TemporaryDirectory(prefix="mpr-scroll-arguments-") as temporary:
            out = Path(temporary) / "local-validation" / "run"
            for arguments in cases:
                with self.subTest(arguments=arguments), contextlib.ExitStack() as stack:
                    app = stack.enter_context(patch.object(runner, "Session"))
                    fixture = stack.enter_context(patch.object(runner, "phantom"))
                    preparing = stack.enter_context(patch.object(runner, "prepare", side_effect=AssertionError("native work started")))
                    stack.enter_context(patch.object(sys, "argv", ["mpr-scroll", "--out", str(out), *arguments]))
                    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                    with self.assertRaises(SystemExit) as rejected:
                        runner.main()
                    self.assertEqual(rejected.exception.code, 2)
                    app.assert_not_called()
                    fixture.assert_not_called()
                    preparing.assert_not_called()

    def test_burst_errors_and_absent_results_fail(self):
        for value in (None, {"error": "no MPR"}, {"exception": "main actor violation"}):
            with self.subTest(value=value):
                self.assert_failed(burst=value)

    def test_partial_empty_and_invalid_event_samples_fail(self):
        partial = complete_burst(3)
        empty = complete_burst(0)
        invalid = complete_burst(4)
        invalid["events"][1][1] = float("nan")
        for value in (partial, empty, invalid):
            with self.subTest(value=value):
                self.assert_failed(burst=value)

    def test_process_death_without_burst_answer_fails(self):
        self.assert_failed(died=True)

    def test_before_and_after_states_are_required(self):
        for number in (1, 2):
            with self.subTest(state_number=number):
                self.assert_failed(state_fault=None, state_number=number)

    def test_state_errors_missing_views_and_missing_pixels_fail(self):
        missing = copy.deepcopy(STATE)
        missing["views"].pop()
        pixels = copy.deepcopy(STATE)
        pixels["views"][0]["central_mean"] = None
        for value in ({"error": "state unavailable"}, {"exception": "getter failed"}, missing, pixels):
            with self.subTest(value=value):
                self.assert_failed(state_fault=value)

    def test_capture_errors_and_unmeasured_pixels_fail(self):
        unavailable = copy.deepcopy(CAPTURE)
        unavailable["display"] = {"error": "screen capture exited 1"}
        invalid = copy.deepcopy(CAPTURE)
        invalid["window"]["mean"] = float("nan")
        for value in (unavailable, invalid):
            with self.subTest(value=value):
                self.assert_failed(capture=value)

    def command(self, text=UNSET, exit_code=None, timeout=False):
        with tempfile.TemporaryDirectory(prefix="mpr-scroll-command-") as temporary:
            session = runner.Session.__new__(runner.Session)
            answer = Path(temporary) / "answer.json"
            if text is not UNSET:
                answer.write_text(text)
            session.process = SimpleNamespace(poll=lambda: exit_code)
            session.send = Mock(return_value=answer)
            waiting = Mock(side_effect=TimeoutError("command timeout")) if timeout else ready
            with patch.object(runner.native_app, "wait_for", waiting):
                return session.command({"action": "state"}, timeout=1)

    def test_command_reads_the_probe_response(self):
        self.assertEqual(self.command(json.dumps(STATE)), STATE)

    def test_command_rejects_errors_null_and_invalid_json(self):
        for value in ('null', '[]', '{"error":"no state"}', '{"exception":"getter failed"}', '{'):
            with self.subTest(value=value), self.assertRaises((RuntimeError, ValueError)):
                self.command(value)

    def test_command_rejects_process_death(self):
        with self.assertRaises((RuntimeError, ValueError)):
            self.command(exit_code=17)

    def test_command_timeout_is_a_failure(self):
        with self.assertRaises(TimeoutError):
            self.command(timeout=True)


if __name__ == "__main__":
    unittest.main()
