"""Model-free release instrumentation definition and shrinker controls."""
import hashlib
import json
from pathlib import Path
import tempfile
import zipfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import verify_apk


PLUGIN = "dev.flutter.plugins.integration_test.IntegrationTestPlugin"
RUNNER = "dev.flutter.plugins.integration_test.FlutterTestRunner"


class ConsumerInstrumentationTest(unittest.TestCase):
    def test_only_exact_defined_class_rows_count(self):
        observed = verify_apk.parse_defined_classes(
            f"P d 10\t10\t950\tdev.flutter.plugins.integration_test\n"
            f"C d 10\t10\t950\t{PLUGIN}\n"
            f"C r 0\t0\t0\t{RUNNER}\n"
            f"M d 1\t1\t52\t{RUNNER} <init>()\n"
            f"C d 1\t1\t100\t{RUNNER}Suffix\n")
        self.assertEqual(observed, {PLUGIN, RUNNER + "Suffix"})
        for row in [f"C d x 1 1 {PLUGIN}", f"C d 1 1 {PLUGIN}"]:
            with self.assertRaises(ValueError):
                verify_apk.parse_defined_classes(row)

    def inspect(self, output, code=0):
        def run(argv, **kwargs):
            self.assertEqual(argv, ["/sdk/apkanalyzer", "dex", "packages", "--defined-only", "/app.apk"])
            self.assertEqual(kwargs["timeout"], 120)
            kwargs["stdout"].write(output.encode())
            return SimpleNamespace(returncode=code)
        with patch.object(verify_apk.subprocess, "run", side_effect=run):
            return verify_apk.verify_instrumentation_classes(Path("/app.apk"), Path("/sdk/apkanalyzer"))

    def test_missing_referenced_or_obfuscated_instrumentation_fails(self):
        self.assertEqual(self.inspect(f"C d 10 10 950 {PLUGIN}\nC d 6 6 700 {RUNNER}\n"),
                         sorted({PLUGIN, RUNNER}))
        for output in ["", f"C d 10 10 950 {PLUGIN}\n",
                       f"C d 6 6 700 {RUNNER}\n",
                       f"C r 10 10 950 {PLUGIN}\nC r 6 6 700 {RUNNER}\n",
                       "C d 10 10 950 a.b\nC d 6 6 700 a.c\n"]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                self.inspect(output)
        with self.assertRaises(ValueError):
            self.inspect(f"C d 10 10 950 {PLUGIN}\nC d 6 6 700 {RUNNER}\n", code=1)
        with self.assertRaises(ValueError):
            verify_apk.verify_instrumentation_classes(Path("/app.apk"), None)


    def test_consumer_apk_cannot_skip_definition_inspection(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "consumer.apk"
            plan = b'{"schema":1,"scenario":"consumer-cpu"}'
            binding = {"plan_sha256": hashlib.sha256(plan).hexdigest(), "libraries": {}}
            with zipfile.ZipFile(apk, "w") as archive:
                prefix = "assets/llamadart_android_qualification/"
                archive.writestr(prefix + "binding.json", json.dumps(binding))
                archive.writestr(prefix + "plan.json", plan)
            with self.assertRaisesRegex(ValueError, "requires --apkanalyzer"):
                verify_apk.verify(apk, binding, plan)
            with patch.object(verify_apk, "verify_instrumentation_classes",
                              return_value=sorted({PLUGIN, RUNNER})) as inspect:
                result = verify_apk.verify(apk, binding, plan, Path("/sdk/apkanalyzer"))
                inspect.assert_called_once_with(apk, Path("/sdk/apkanalyzer"))
                self.assertEqual(result["instrumentation_classes_defined"], sorted({PLUGIN, RUNNER}))
                self.assertFalse(result["qualified"])
                self.assertFalse(result["android_launch_observed"])


if __name__ == "__main__":
    unittest.main()
