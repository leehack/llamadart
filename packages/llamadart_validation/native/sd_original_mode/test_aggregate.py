"""Owned Python fixtures only: aggregate deadlines never run image/model code."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import owned_capture
import run as operator
import test_operator as protocol_fixtures


class DeadlineClock:
    def __init__(self):
        self.now = 100

    def monotonic(self):
        return self.now

    def sleep(self, _seconds):
        self.now += 1


class AggregateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sd24-aggregate-model-free-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def budget(self, active, total, name="cases"):
        now = operator.time.monotonic()
        return {"phase": name, "started": now, "active_end": now + active, "total_end": now + total}

    def assert_shared_timeout(self, phase, output, seconds):
        clock = DeadlineClock()
        wait_timeouts = []
        real_popen = subprocess.Popen

        def launch(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            real_wait = child.wait

            def reap():
                if child.poll() is None:
                    child.kill()
                real_wait(timeout=3)

            def record_wait(timeout=None):
                wait_timeouts.append(timeout)
                return real_wait(timeout=timeout)

            self.addCleanup(reap)
            child.wait = record_wait
            return child

        with (patch.object(operator, "time", clock),
              patch.object(owned_capture, "time", clock),
              patch.object(owned_capture.subprocess, "Popen", launch)):
            budget = self.budget(active=1, total=3.5, name=phase)
            with self.assertRaisesRegex(ValueError, "^owned phase/case failed$"):
                operator.run_owned([sys.executable, "-c", "import time;time.sleep(60)"], output,
                                   {"phase": phase, "model_inference": False}, seconds=seconds, budget=budget)

        record = json.loads((output / "capture.json").read_text())
        self.assertTrue(record["timed_out"])
        self.assertTrue(record["shared_deadline_reached"])
        self.assertTrue(record["leader_reaped"])
        self.assertEqual(record["exit"], -signal.SIGKILL)
        self.assertEqual(record["cleanup_errors"], [])
        self.assertEqual(record["elapsed_seconds"], 1)
        self.assertEqual(wait_timeouts, [2.5])
        with self.assertRaises(ProcessLookupError):
            os.kill(record["pid"], 0)

    def test_shared_deadline_wins_and_owned_child_is_killed_reaped(self):
        self.assert_shared_timeout("cases", self.root / "short", seconds=177)

    def test_expired_budget_cannot_launch_or_accept_stale_pass(self):
        budget = self.budget(active=-1, total=1)
        with patch.object(operator, "capture") as launch:
            with self.assertRaises(operator.PhaseTimeout):
                operator.run_owned([sys.executable], self.root / "no-launch", {}, seconds=7, budget=budget)
            launch.assert_not_called()
        record = {"pid": 123, "exit": 0, "leader_reaped": True, "cleanup_errors": [], "timed_out": False,
                  "capture_limit_exceeded": False, "received_signals": [], "failure_type": None}
        budget = self.budget(active=1, total=2)
        def late(*args, **kwargs):
            budget["active_end"] = time.monotonic() - 1
            return record
        with patch.object(operator, "capture", side_effect=late):
            with self.assertRaises(operator.PhaseTimeout):
                operator.run_owned([sys.executable], self.root / "stale-pass", {}, seconds=7, budget=budget)

    def test_unknown_cleanup_is_never_a_no_child_phase(self):
        record = {"pid": 123, "leader_reaped": False, "cleanup_errors": ["TimeoutExpired"]}
        with patch.object(operator, "capture", return_value=record):
            with self.assertRaises(operator.CleanupUnknown):
                operator.run_owned([sys.executable], self.root / "unknown", {}, seconds=7, budget=self.budget(1, 2))

    def test_phase_caps_and_onset_are_absolute_not_refreshed(self):
        for phase, expected in (("preflight", (57, 60)), ("cases", (1074, 1080)), ("post", (7, 10))):
            with patch.object(operator.time, "monotonic", return_value=100):
                budget = operator.phase_budget(phase)
            self.assertEqual((budget["active_end"], budget["total_end"]), (100 + expected[0], 100 + expected[1]))
            with patch.object(operator.time, "monotonic", return_value=budget["active_end"]):
                with self.assertRaises(operator.PhaseTimeout): operator.before_deadline(budget)

    def test_real_prehash_grade_and_post_worker_deadlines_are_charged(self):
        for phase in ("preflight", "cases", "post"):
            with self.subTest(phase=phase):
                self.assert_shared_timeout(phase, self.root / phase, seconds=7)

    def test_scoped_git_children_are_owned_and_reaped(self):
        # The actual fixed source metadata commands, not a fake launcher.
        import shutil
        git = shutil.which("git")
        self.assertIsNotNone(git)
        command = [git, "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                   "-c", "core.hooksPath=/dev/null", "--no-pager", "-C", str(operator.REPO), "rev-parse", "HEAD"]
        record = operator.run_owned(command, self.root / "git", {"phase": "preflight-git", "model_inference": False},
                                    seconds=5, budget=self.budget(5, 8))
        self.assertTrue(record["leader_reaped"])
        self.assertRegex((self.root / "git/stdout.log").read_text().strip(), r"^[0-9a-f]{40}$")
        with self.assertRaises(ProcessLookupError): os.kill(record["pid"], 0)

    def test_data_only_grader_preserves_baseline_pixels_without_stdout_payload(self):
        fixture = protocol_fixtures.OperatorTest()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        directory, rgb = fixture.fixture("native-safetensors")
        plan = fixture.plan()
        plan["nativeLibrary"] = fixture.bound
        # Pure grader invocation on synthetic protocol/RGB; no model process.
        operator.phase_worker("grade", plan, fixture.root, "native-safetensors")
        result = json.loads((directory / "grade.json").read_text())
        self.assertTrue(result["passed"])
        self.assertEqual((directory / "image.ppm").read_bytes()[len(operator.PREFIX):], rgb)
        self.assertLess((directory / "grade.json").stat().st_size, 2048)


if __name__ == "__main__": unittest.main()
