"""Model-free build-contract tests, including compilation of both native adapters."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

HELPER = Path(__file__).resolve().parents[1] / "build_android_release_acceptance.py"
sys.path.insert(0, str(HELPER.parent))
spec = importlib.util.spec_from_file_location("acceptance", HELPER)
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class ReleaseAcceptanceTest(unittest.TestCase):
    def test_release_commands_bind_fixture_and_identical_defines(self):
        app, test = acceptance.build_commands("a" * 40, "b" * 64)
        self.assertIn("--release", app)
        self.assertIn(acceptance.TARGET, app)
        self.assertIn("app:assembleReleaseAndroidTest", test)
        import base64
        encoded = next(value.split("=", 1)[1] for value in test
                       if value.startswith("-Pdart-defines="))
        self.assertEqual([base64.b64decode(value).decode() for value in encoded.split(",")],
                         [value.split("=", 1)[1] for value in app
                          if value.startswith("--dart-define=")])
        ordinary = acceptance.build_commands("a" * 40, None, True)
        self.assertEqual(len(ordinary), 1)
        self.assertIn("lib/main.dart", ordinary[0])
        self.assertFalse(any("STUDIO_CLOUD" in value for value in ordinary[0]))

    def test_missing_runner_and_production_plugin_leak_fail_closed(self):
        with self.assertRaises(ValueError):
            acceptance.check_classes(acceptance.PLUGIN, False)
        with self.assertRaises(ValueError):
            acceptance.check_classes(acceptance.RUNNER, False)
        acceptance.check_classes(acceptance.PLUGIN + acceptance.RUNNER, False)
        acceptance.check_classes("dev.llamadart.studio.MainActivity", True)
        for leaked in (acceptance.PLUGIN, acceptance.RUNNER):
            with self.assertRaises(ValueError):
                acceptance.check_classes(leaked, True)

    def test_aot_rejects_missing_wrong_arch_and_kernel_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            elf = b"\x7fELF" + bytes(14) + (183).to_bytes(2, "little")
            for entries, succeeds in [({}, False),
                    ({"lib/arm64-v8a/libapp.so": b"wrong"}, False),
                    ({"lib/arm64-v8a/libapp.so": elf, "assets/kernel_blob.bin": b""}, False),
                    ({"lib/arm64-v8a/libapp.so": elf}, True)]:
                with zipfile.ZipFile(apk, "w") as archive:
                    for name, data in entries.items():
                        archive.writestr(name, data)
                if succeeds:
                    acceptance.check_aot(apk)
                else:
                    with self.assertRaises(ValueError):
                        acceptance.check_aot(apk)

    def test_native_registration_is_idempotent_and_ordinary_needs_no_plugin(self):
        # Compile the maintained Java unchanged. The engine double observes actual
        # registry calls; no integration_test symbol exists in the ordinary lane.
        java_home = Path(os.environ["JAVA_HOME"])
        source = acceptance.APP / "android/app/src"
        for variant in ("ordinary", "releaseAcceptance"):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                files = {
                    "io/flutter/embedding/engine/FlutterEngine.java": ENGINE,
                    "dev/llamadart/studio/RegistrationTest.java": HARNESS,
                }
                if variant == "releaseAcceptance":
                    files["dev/flutter/plugins/integration_test/IntegrationTestPlugin.java"] = PLUGIN
                for name, data in files.items():
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(data)
                adapter = source / variant / "java/dev/llamadart/studio/StudioAcceptanceRegistration.java"
                compile_result = subprocess.run(
                    [str(java_home / "bin/javac"), "-d", str(root),
                     *map(str, root.rglob("*.java")), str(adapter)], capture_output=True, text=True)
                self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
                result = subprocess.run(
                    [str(java_home / "bin/java"), "-cp", str(root),
                     "dev.llamadart.studio.RegistrationTest",
                     "1" if variant == "releaseAcceptance" else "0"], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)


ENGINE = """
package io.flutter.embedding.engine;
public final class FlutterEngine {
    public final Registry registry = new Registry();
    public Registry getPlugins() { return registry; }
    public static final class Registry {
        public int additions;
        private Object plugin;
        public boolean has(Class<?> type) { return plugin != null && type.isInstance(plugin); }
        public void add(Object value) { plugin = value; additions++; }
    }
}
"""
PLUGIN = """
package dev.flutter.plugins.integration_test;
public final class IntegrationTestPlugin {}
"""
HARNESS = """
package dev.llamadart.studio;
import io.flutter.embedding.engine.FlutterEngine;
public final class RegistrationTest {
    public static void main(String[] args) {
        FlutterEngine engine = new FlutterEngine();
        StudioAcceptanceRegistration.registerWith(engine);
        StudioAcceptanceRegistration.registerWith(engine);
        if (engine.registry.additions != Integer.parseInt(args[0])) {
            throw new AssertionError("Wrong plugin registration count: " + engine.registry.additions);
        }
    }
}
"""

if __name__ == "__main__":
    unittest.main()
