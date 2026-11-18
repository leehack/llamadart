"""Model-free negative tests for the closed stage and build routing."""

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_android_release_acceptance as android
import build_ios_release_acceptance as ios
import mobile_default_assets as mobile
import stage_ios_mobile_default as staging


class MobileDefaultAcceptanceTest(unittest.TestCase):
    def test_manifest_rejects_extra_url_path_hash_size_and_missing_companion(self):
        mobile.validate_manifest(copy.deepcopy(mobile.MANIFEST))
        for mutation in ("url", "path", "hash", "size", "missing", "schema", "float-size", "bool-schema"):
            value = copy.deepcopy(mobile.MANIFEST)
            primary, projector = mobile.ASSETS
            if mutation == "url":
                value["url"] = "https://example.invalid/model"
            elif mutation == "path":
                value["assets"]["../" + primary] = value["assets"].pop(primary)
            elif mutation == "hash":
                value["assets"][primary]["sha256"] = "0" * 64
            elif mutation == "size":
                value["assets"][primary]["bytes"] += 1
            elif mutation == "missing":
                del value["assets"][projector]
            elif mutation == "float-size":
                value["assets"][primary]["bytes"] = float(value["assets"][primary]["bytes"])
            elif mutation == "bool-schema":
                value["schema"] = True
            else:
                value["schema"] = 2
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                mobile.validate_manifest(value)

    def test_stage_hashes_source_and_copy_and_rejects_extra_files_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            primary, projector = root / "primary", root / "projector"
            primary.write_bytes(b"primary")
            projector.write_bytes(b"projector")
            # Small deterministic bytes exercise the same real hashing/copy path.
            assets = dict(zip(mobile.ASSETS, [mobile.digest(primary), mobile.digest(projector)]))
            with patch.object(mobile, "ASSETS", assets), patch.object(mobile, "MANIFEST", {"schema": 1, "assets": assets}):
                stage = root / "stage"
                mobile.stage_assets(primary, projector, stage)
                mobile.verify_stage(stage)
                extra = stage / "nomic.gguf"
                extra.touch()
                with self.assertRaises(ValueError):
                    mobile.verify_stage(stage)
                extra.unlink()
                staged_primary = stage / next(iter(assets))
                staged_primary.write_bytes(b"tampered")
                with self.assertRaises(ValueError):
                    mobile.verify_stage(stage)
                staged_primary.unlink()
                staged_primary.symlink_to(primary)
                with self.assertRaises(ValueError):
                    mobile.verify_stage(stage)
                primary.write_bytes(b"bad source")
                with self.assertRaises(ValueError):
                    mobile.stage_assets(primary, projector, root / "bad-source")

    def test_android_suite_selector_preserves_default_and_identical_defines(self):
        old = android.build_commands("a" * 40, "b" * 64)
        self.assertIn(android.TARGET, old[0])
        identity = {"source_commit": "a" * 40, "test": "Unicode — ✓"}
        app, test = android.build_commands("a" * 40, None, suite="default-workflows", identity=identity)
        self.assertIn(mobile.TARGET, app)
        defines = [v.split("=", 1)[1] for v in app if v.startswith("--dart-define=")]
        encoded = next(v.split("=", 1)[1] for v in test if v.startswith("-Pdart-defines="))
        self.assertEqual(defines, [base64.b64decode(v).decode() for v in encoded.split(",")])
        self.assertIn("STUDIO_MOBILE_DEFAULT_ACCEPTANCE=true", defines)
        self.assertFalse(any("STUDIO_CLOUD" in v for v in defines))
        for suite in ("../evil.dart", "default-workflows"):
            with self.assertRaises(ValueError):
                android.build_commands("a" * 40, None, ordinary=True, suite=suite)

    def test_android_apk_excludes_model_and_qualification_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "test.apk"
            for name in ("assets/model.gguf", "assets/studio-mobile-default-models/manifest.json",
                         "assets/mobile_default/binding.json", "assets/qualification/binding.json"):
                with zipfile.ZipFile(apk, "w") as archive:
                    archive.writestr(name, b"payload")
                with self.assertRaises(ValueError):
                    android.check_payload_exclusion(apk)

    def test_ios_commands_sign_release_build_for_testing_and_ordinary_cannot_stage(self):
        config, build = ios.build_commands(Path("/output"), "TEAM", {}, Path("/models"))
        self.assertIn(mobile.TARGET, config)
        self.assertIn("build-for-testing", build)
        self.assertIn("Release", build)
        self.assertIn("CODE_SIGNING_ALLOWED=YES", build)
        self.assertIn("STUDIO_MOBILE_DEFAULT_ACCEPTANCE=YES", build)
        config, build = ios.build_commands(Path("/output"), "TEAM", {}, ordinary=True)
        self.assertIn("lib/main.dart", config)
        self.assertIn("build", build)
        self.assertFalse(any("STUDIO_MOBILE_DEFAULT_IDENTITY" in v for v in config))
        with self.assertRaises(ValueError):
            ios.build_commands(Path("/output"), "TEAM", {}, Path("/models"), ordinary=True)

    def test_ios_phase_rejects_wrong_target_define_platform_signing_and_config(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {"TARGET_BUILD_DIR": directory, "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Runner.app",
                   "STUDIO_MOBILE_DEFAULT_ACCEPTANCE": "YES", "STUDIO_MOBILE_DEFAULT_MODELS": "/models",
                   "CONFIGURATION": "Release", "SDK_NAME": "iphoneos26.1", "CODE_SIGNING_ALLOWED": "YES",
                   "FLUTTER_TARGET": mobile.TARGET,
                   "DART_DEFINES": base64.b64encode(b"STUDIO_MOBILE_DEFAULT_ACCEPTANCE=true").decode()}
            for key, bad in (("FLUTTER_TARGET", "lib/main.dart"),
                             ("FLUTTER_TARGET", "/unrelated/" + mobile.TARGET), ("DART_DEFINES", ""),
                             ("CONFIGURATION", "Debug"), ("SDK_NAME", "iphonesimulator26.1"),
                             ("CODE_SIGNING_ALLOWED", "NO"), ("STUDIO_MOBILE_DEFAULT_ACCEPTANCE", "NO")):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    staging.stage({**env, key: bad})
            resource = Path(directory) / "Runner.app" / mobile.RESOURCE
            resource.mkdir(parents=True)
            (resource / "model.gguf").write_bytes(b"stale")
            staging.stage({"TARGET_BUILD_DIR": directory, "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Runner.app"})
            self.assertFalse(resource.exists())
            ios.check_payloads(resource.parent, True)
            (resource.parent / "leaked.gguf").touch()
            with self.assertRaises(ValueError):
                ios.check_payloads(resource.parent, True)

    def test_ios_phase_copies_only_verified_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            primary, projector = root / "p", root / "v"
            primary.write_bytes(b"p")
            projector.write_bytes(b"v")
            assets = dict(zip(mobile.ASSETS, [mobile.digest(primary), mobile.digest(projector)]))
            with patch.object(mobile, "ASSETS", assets), patch.object(mobile, "MANIFEST", {"schema": 1, "assets": assets}):
                mobile.stage_assets(primary, projector, root / "input")
                env = {"TARGET_BUILD_DIR": str(root), "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Runner.app",
                       "STUDIO_MOBILE_DEFAULT_ACCEPTANCE": "YES", "STUDIO_MOBILE_DEFAULT_MODELS": str(root / "input"),
                       "CONFIGURATION": "Release", "SDK_NAME": "iphoneos26.1", "CODE_SIGNING_ALLOWED": "YES",
                       "FLUTTER_TARGET": mobile.TARGET,
                       "DART_DEFINES": base64.b64encode(b"STUDIO_MOBILE_DEFAULT_ACCEPTANCE=true").decode()}
                staging.stage(env)
                ios.check_payloads(root / "Runner.app", False)

    def test_java_stream_copy_hash_size_and_no_partial_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = root / "StagingTest.java"
            harness.write_text(JAVA_TEST)
            source = android.APP / "android/app/src/androidTest/java/dev/llamadart/studio/MobileDefaultModelStaging.java"
            java = Path(os.environ["JAVA_HOME"]) / "bin"
            result = subprocess.run([str(java / "javac"), "-d", str(root), str(source), str(harness)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(java / "java"), "-cp", str(root), "dev.llamadart.studio.StagingTest", str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Cross-language pins guard the actual native stage, not a test copy.
            for name, expected in mobile.ASSETS.items():
                self.assertIn(name, source.read_text())
                self.assertIn(str(expected["bytes"]) + "L", source.read_text())
                self.assertIn(expected["sha256"], source.read_text())

    def test_build_identity_rejects_unprepared_sdk_and_tracks_compiler_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            app, sdk = repo / "app", repo / "sdk"
            inputs = [app / mobile.TARGET, repo / "lib/src/hook/native_release_pins.dart",
                      sdk / "bin/cache/dart-sdk/bin/dart",
                      sdk / "bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot",
                      sdk / "bin/cache/flutter_tools.snapshot"]
            for path in inputs:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"frozen")
            def git(command, **kwargs):
                return "" if "status" in command else "a" * 40 + "\n"
            with patch.object(mobile.subprocess, "check_output", side_effect=git):
                with self.assertRaises(ValueError):
                    mobile.build_identity(repo, app, sdk, "b" * 40, "ios")
                compiler = sdk / "bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64"
                compiler.parent.mkdir(parents=True)
                compiler.write_bytes(b"compiler-before")
                before = mobile.build_identity(repo, app, sdk, "b" * 40, "ios")
                compiler.write_bytes(b"compiler-after")
                self.assertNotEqual(before, mobile.build_identity(repo, app, sdk, "b" * 40, "ios"))
            with patch.object(mobile.subprocess, "check_output", return_value=" M framework.dart"):
                with self.assertRaises(ValueError):
                    mobile.build_identity(repo, app, sdk, "b" * 40, "ios")


JAVA_TEST = r'''
package dev.llamadart.studio;
import java.io.*;
public final class StagingTest {
  public static void main(String[] args) throws Exception {
    File root = new File(args[0]);
    String sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    File target = new File(root, "model");
    MobileDefaultModelStaging.copyVerified(new ByteArrayInputStream("abc".getBytes("UTF-8")), target, 3, sha);
    if (target.length() != 3) throw new AssertionError("Missing success copy");
    for (String bytes : new String[]{"ab", "abcd", "abd"}) {
      target.delete();
      try {
        MobileDefaultModelStaging.copyVerified(new ByteArrayInputStream(bytes.getBytes("UTF-8")), target, 3, sha);
        throw new AssertionError("Accepted bad bytes");
      } catch (IOException expected) {}
      if (target.exists() || new File(target.getPath() + ".tmp").exists())
        throw new AssertionError("Published failed or partial input");
    }
    File stale = new File(root, MobileDefaultModelStaging.DIRECTORY);
    stale.mkdir();
    try {
      MobileDefaultModelStaging.stage(root, name -> { throw new AssertionError("Read stale stage"); });
      throw new AssertionError("Accepted stale stage");
    } catch (IOException expected) {}
  }
}
'''

if __name__ == "__main__":
    unittest.main()
