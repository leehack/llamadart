"""Synthetic protocol/graph controls; never opens the pinned original files."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run as operator


class OperatorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sd24-operator-model-free-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.library = self.root / "synthetic-library"
        self.library.write_bytes(b"synthetic, never loaded")
        self.bound = {"path": str(self.library), "sha256": operator.digest(self.library)}
        self.executable = self.root / "synthetic-macho-header"
        self.executable.write_bytes(bytes.fromhex("cffaedfe") + b"not executable")
        self.snapshot = self.root / "synthetic-kernel-header"
        self.snapshot.write_bytes(bytes.fromhex("90abcdef") + b"not executable")

    def plan(self):
        plan = {"schema": 1, "scope": "pr41-original-mode-diagnostic", "ownerCommit": operator.OWNER,
                "sourceCommit": "a" * 40, "artifactRun": 41673639935, "artifactId": 13249907568,
                "models": [{"id": name, "sha256": sha, "bytes": size, "path": "/synthetic/" + name}
                           for name, sha, size in operator.MODELS],
                "taesd": {"path": "/synthetic/taesd", "sha256": operator.TAESD, "bytes": 9793292}}
        for key in ("nativeExecutable", "dartExecutable", "publicSnapshot", "nativeLibrary", "publicLibrary", "artifactReview", "sourceAdmission", "nativeAssets", "nativeBuildReceipt", "publicBuildReceipt", "runtimeStagingReceipt"):
            plan[key] = dict(self.bound)
        plan["nativeLibrary"]["sha256"] = operator.LIBRARY
        plan["artifactReview"]["sha256"] = operator.ARTIFACT_REVIEW
        for key in ("nativeExecutable", "dartExecutable"):
            plan[key] = {"path": str(self.executable), "sha256": operator.digest(self.executable)}
        plan["publicSnapshot"] = {"path": str(self.snapshot), "sha256": operator.digest(self.snapshot)}
        return plan

    def fixture(self, name, route="native", load_ms=3, pixels=None, stages=None):
        directory = self.root / name
        directory.mkdir()
        rows = stages or [{"schema": 1, "stage": s, "elapsedMs": i, "loadMs": load_ms} for i, s in enumerate(operator.STAGES)]
        binding = {"schema": 1, "route": route, "mappedLibraryPath": str(self.library), "mappedLibrarySha256": self.bound["sha256"]}
        data = "".join("SD24_STAGE " + json.dumps(row) + "\n" for row in rows)
        data += "SD24_BINDING " + json.dumps(binding) + "\n"
        data += "SD24_CONFIG " + json.dumps(operator.CONFIG) + "\n"
        if route == "public": data += 'SD24_PUBLIC {"backend":"CPU","family":"SD 2.x"}\n'
        (directory / "stdout.log").write_text(data)
        (directory / "stderr.log").write_bytes(b"FAMILY=SD 2.x\n")
        rgb = pixels if pixels is not None else bytes(range(256)) * 192
        (directory / "image.ppm").write_bytes(operator.PREFIX + rgb)
        record = {"exit": 0, "leader_reaped": True, "deadline_seconds": 177, "cleanup_deadline_seconds": 3,
                  "timed_out": False, "capture_limit_exceeded": False, "cleanup_errors": [], "failure_type": None,
                  "received_signals": [], "raw": {}}
        for filename in ("stdout.log", "stderr.log"):
            path = directory / filename
            record["raw"][filename] = {"sha256": operator.digest(path), "bytes": path.stat().st_size}
        (directory / "capture.json").write_text(json.dumps(record))
        return directory, rgb

    def grade(self, directory, route="native", baseline=None, paired=None):
        plan = {"nativeLibrary": self.bound, "publicLibrary": self.bound}
        return operator.grade(directory, {"route": route}, plan, baseline, paired)

    def test_native_baseline_public_pair_and_unmodified_raw_hashes(self):
        native, rgb = self.fixture("native")
        self.assertEqual(self.grade(native), rgb)
        public, _ = self.fixture("public", route="public")
        self.assertEqual(self.grade(public, "public", rgb, rgb), rgb)
        (public / "stderr.log").write_bytes(b"tampered")
        with self.assertRaises(ValueError): self.grade(public, "public", rgb, rgb)

    def test_late_load_trivial_pixels_wrong_parity_and_missing_disposal_fail(self):
        for name in ("late", "trivial", "parity", "dispose"):
            with self.subTest(case=name):
                directory, rgb = self.fixture(name, load_ms=45000 if name == "late" else 3,
                    pixels=bytes(49152) if name == "trivial" else None,
                    stages=[{"schema": 1, "stage": s, "elapsedMs": i, "loadMs": 3} for i, s in enumerate(operator.STAGES[:-1])] if name == "dispose" else None)
                with self.assertRaises(ValueError):
                    self.grade(directory, baseline=bytes(49152) if name == "parity" else None)
                self.assertTrue((directory / "image-receipt.json").is_file(), "raw output must be hash-bound before grading")

    def test_original_input_or_scope_substitution_is_rejected(self):
        plan = self.plan()
        operator.validate_plan(plan)
        for key in ("model", "taesd", "runtime", "scope"):
            changed = copy.deepcopy(plan)
            if key == "model": changed["models"][1]["sha256"] = "0" * 64
            if key == "taesd": changed["taesd"]["sha256"] = "0" * 64
            if key == "runtime": changed["nativeLibrary"]["sha256"] = "0" * 64
            if key == "scope": changed["scope"] = "published-qualified"
            with self.assertRaises(ValueError): operator.validate_plan(changed)
        wrong = {**self.bound, "sha256": "0" * 64}
        with self.assertRaises(ValueError): operator.verify(wrong)

    def test_first_baseline_failure_stops_all_remaining_children(self):
        output = self.root / "run"
        def git(args, **kwargs): return "a" * 40 + "\n" if "rev-parse" in args else b""
        def captured(argv, directory, identity, **kwargs): directory.mkdir()
        with patch.object(operator.sys, "platform", "darwin"), patch.object(operator.platform, "machine", return_value="arm64"), \
             patch.object(operator, "verify", return_value={}), patch.object(operator.subprocess, "check_output", side_effect=git), \
             patch.object(operator, "capture", side_effect=captured) as child, \
             patch.object(operator, "grade", side_effect=ValueError("synthetic baseline failure")):
            with self.assertRaisesRegex(ValueError, "baseline failure"):
                operator.execute(self.plan(), output)
        self.assertEqual(child.call_count, 1)
        self.assertEqual(child.call_args.kwargs["seconds"], 177,
                         "active deadline must reserve three seconds inside the 180-second case cap")
        summary = json.loads((output / "summary.json").read_text())
        self.assertFalse(summary["diagnosticPassed"])
        self.assertEqual([r["status"] for r in summary["cases"]], ["FAIL"] + ["NOT_RUN"] * 5)

    def test_fixed_six_case_graph_and_strict_total_budget(self):
        rows = operator.commands(self.plan(), self.root)
        self.assertEqual([r["id"] for r in rows], ["native-safetensors", "public-safetensors", "native-flat", "public-flat", "native-nested", "public-nested"])
        self.assertIn("--original-mode", rows[0]["argv"])
        self.assertEqual(rows[1]["argv"][1], str(self.snapshot))


if __name__ == "__main__": unittest.main()
