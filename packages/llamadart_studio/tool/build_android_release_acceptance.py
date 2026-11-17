#!/usr/bin/env python3
"""Build and retain a Studio release acceptance pair; never run or upload it."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

import mobile_default_assets as mobile

APP = Path(__file__).resolve().parents[1]
REPO = APP.parents[1]
TARGET = "integration_test/cloud_mobile_acceptance_test.dart"
PLUGIN = "dev.flutter.plugins.integration_test.IntegrationTestPlugin"
RUNNER = "dev.flutter.plugins.integration_test.FlutterTestRunner"


def digest(path):
    with path.open("rb") as stream:
        return {"sha256": hashlib.file_digest(stream, "sha256").hexdigest(),
                "bytes": path.stat().st_size}


def build_commands(source, model_sha, ordinary=False, suite="diagnostic", identity=None):
    if suite not in ("diagnostic", "default-workflows"):
        raise ValueError("Unknown acceptance suite")
    if ordinary and suite != "diagnostic":
        raise ValueError("Ordinary builds cannot select an acceptance suite")
    defines = [] if ordinary or suite == "default-workflows" else [
        "STUDIO_CLOUD_ACCEPTANCE=true",
        "STUDIO_CLOUD_SOURCE_COMMIT=" + source,
        "STUDIO_CLOUD_MODEL_SHA256=" + model_sha,
    ]
    target = "lib/main.dart" if ordinary else TARGET
    if not ordinary and suite == "default-workflows":
        target = mobile.TARGET
        defines = ["STUDIO_MOBILE_DEFAULT_ACCEPTANCE=true",
                   "STUDIO_MOBILE_DEFAULT_IDENTITY=" + json.dumps(identity, separators=(",", ":"))]
    app = ["flutter", "build", "apk", "--release", "--target", target,
           "--target-platform", "android-arm64"]
    app += ["--dart-define=" + value for value in defines]
    instrumentation = [
        "./gradlew", "app:assembleReleaseAndroidTest", "-Ptarget=" + target,
        "-Ptarget-platform=android-arm64",
        "-Pdart-defines=" + ",".join(base64.b64encode(value.encode()).decode()
                                   for value in defines),
    ]
    return [app] if ordinary else [app, instrumentation]


def check_aot(apk):
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if "lib/arm64-v8a/libapp.so" not in names:
            raise ValueError("Missing arm64 AOT libapp.so")
        if any("kernel_blob" in name for name in names):
            raise ValueError("Unexpected kernel blob in release APK")
        elf = archive.read("lib/arm64-v8a/libapp.so")
        if elf[:4] != b"\x7fELF" or int.from_bytes(elf[18:20], "little") != 183:
            raise ValueError("libapp.so must be an AArch64 ELF")


def check_classes(classes, ordinary):
    for name in (PLUGIN, RUNNER):
        if (name in classes) == ordinary:
            raise ValueError("Unexpected integration_test inclusion/exclusion: " + name)


def check_payload_exclusion(apk):
    with zipfile.ZipFile(apk) as archive:
        if any(name.lower().endswith(".gguf") or mobile.RESOURCE in name
               or "mobile_default" in name or "qualification" in name
               for name in archive.namelist()):
            raise ValueError("Unexpected model/qualification payload in APK")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", required=True, type=Path)
    parser.add_argument("--android-sdk", required=True, type=Path)
    parser.add_argument("--build-tools", default="36.1.0")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model-sha256")
    parser.add_argument("--suite", choices=("diagnostic", "default-workflows"), default="diagnostic")
    parser.add_argument("--models", type=Path, help="Verified local allowlist directory for default-workflows")
    parser.add_argument("--ordinary", action="store_true",
                        help="Build lib/main.dart and verify release test-plugin exclusion")
    args = parser.parse_args()
    import re
    if args.ordinary and (args.suite != "diagnostic" or args.models):
        parser.error("Ordinary builds cannot stage or select acceptance inputs")
    if args.suite == "default-workflows":
        if args.models is None or args.model_sha256 is not None:
            parser.error("default-workflows requires --models and no diagnostic hash override")
        mobile.verify_stage(args.models)
    elif args.models:
        parser.error("--models is only valid with default-workflows")
    if not args.ordinary and args.suite == "diagnostic" and not re.fullmatch(r"[a-f0-9]{64}", args.model_sha256 or ""):
        parser.error("--model-sha256 requires the admitted model SHA-256")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    # Do not inherit unrelated qualification overlays or Gradle instrumentation flags.
    for name in ("LLAMADART_ANDROID_QUALIFICATION_STAGE",
                 "LLAMADART_ANDROID_CONSUMER_PROFILE_STAGE", "LLAMADART_VALIDATION_NPU_STAGE",
                 "ORG_GRADLE_PROJECT_studioReleaseAcceptance"):
        if name in env:
            raise ValueError("Unset inherited build input: " + name)
    env["PATH"] = os.pathsep.join([str(args.flutter_sdk.resolve() / "bin"), env["PATH"]])
    env["ANDROID_HOME"] = str(args.android_sdk.resolve())
    env["ORG_GRADLE_PROJECT_studioReleaseAcceptance"] = str(not args.ordinary).lower()
    receipt = {"qualified": False, "deviceExecuted": False, "ordinary": args.ordinary,
               "suite": args.suite, "sourceOverlay": None, "commands": [], "status": "building"}

    def run(command, cwd, name):
        receipt["commands"].append({"argv": list(map(str, command)),
                                    "cwd": str(cwd), "log": name})
        result = subprocess.run(command, cwd=cwd, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (output / name).write_text(result.stdout)
        if result.stderr:
            (output / (name + ".stderr")).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"{name}: exit {result.returncode}")
        return result.stdout

    def clean():
        status = subprocess.check_output(["git", "status", "--porcelain"], cwd=REPO, text=True)
        if status.strip():
            raise ValueError("Commit source changes before a provenance build: " + status)

    try:
        clean()
        source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
        receipt["source"] = source
        receipt["tree"] = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=REPO, text=True).strip()
        receipt["qualificationDebugSigningAllowed"] = env.get(
            "ORG_GRADLE_PROJECT_studioAllowDebugSigningForQualification") == "true"
        receipt["modelSha256"] = args.model_sha256
        identity = None
        if args.suite == "default-workflows":
            identity = mobile.build_identity(REPO, APP, args.flutter_sdk.resolve(), source, "android")
            receipt["identity"] = identity
            # Retained shell inputs are separate from both APKs.
            shutil.copytree(args.models, output / mobile.RESOURCE)
            mobile.verify_stage(output / mobile.RESOURCE)
            receipt["modelManifest"] = mobile.MANIFEST
        receipt["buildMode"] = "release"
        receipt["bareTools"] = {name: shutil.which(name, path=env["PATH"])
                                for name in ("flutter", "dart", "java")}
        for name in ("flutter", "dart"):
            expected = args.flutter_sdk.resolve() / "bin" / name
            if Path(receipt["bareTools"][name]).resolve() != expected.resolve():
                raise ValueError("Wrong bare SDK tool: " + name)
        version = json.loads(run(["flutter", "--version", "--machine"], APP, "flutter-version.json"))
        if version["frameworkVersion"] != (APP / ".flutter-version").read_text().strip():
            raise ValueError("Flutter SDK does not match Studio pin")
        run(["dart", "--version"], APP, "dart-version.txt")
        # Keep the exact committed inputs, not an unrecorded source overlay.
        subprocess.run(["git", "archive", "--format=tar", "-o", str(output / "source.tar"), source],
                       cwd=REPO, check=True)
        sdk_plugin = args.flutter_sdk.resolve() / "packages/integration_test"
        shutil.copytree(sdk_plugin / "android", output / "sdk-integration-test-android",
                        ignore=shutil.ignore_patterns(".gradle", "build"))
        run(["dart", "pub", "get"], APP.parent / "llamadart_studio_core", "resolve-core.log")
        run(["flutter", "pub", "get"], APP, "resolve-ui.log")
        clean()
        for index, command in enumerate(build_commands(source, args.model_sha256, args.ordinary,
                                                        args.suite, identity)):
            run(command, APP if index == 0 else APP / "android", f"build-{index}.log")
        paths = {"app.apk": APP / "build/app/outputs/flutter-apk/app-release.apk"}
        if not args.ordinary:
            paths["test.apk"] = APP / "build/app/outputs/apk/androidTest/release/app-release-androidTest.apk"
        tools = args.android_sdk / "build-tools" / args.build_tools
        analyzer = args.android_sdk / "cmdline-tools/latest/bin/apkanalyzer"
        signatures = []
        for name, path in paths.items():
            retained = output / name
            shutil.copyfile(path, retained)
            signature = run([str(tools / "apksigner"), "verify", "--verbose", "--print-certs",
                             str(retained)], APP, name + ".signature.txt")
            signatures.append(re.search(r"Signer #1 certificate SHA-256 digest: (.+)", signature).group(1))
        if len(set(signatures)) != 1:
            raise ValueError("App and instrumentation signatures differ")
        receipt["signerCertificateSha256"] = signatures[0]
        debuggable = run([str(analyzer), "manifest", "debuggable", str(output / "app.apk")],
                         APP, "debuggable.txt").strip()
        if debuggable != "false":
            raise ValueError("Release app is debuggable")
        check_aot(output / "app.apk")
        for name in paths:
            check_payload_exclusion(output / name)
        receipt["debuggable"] = False
        receipt["aotArchitecture"] = "arm64-v8a"
        classes = run([str(analyzer), "dex", "packages", "--defined-only", str(output / "app.apk")],
                      APP, "app-dex-packages.txt")
        check_classes(classes, args.ordinary)
        if not args.ordinary:
            wiring = run([str(analyzer), "dex", "code", "--class", "dev.llamadart.studio.MainActivity",
                          str(output / "app.apk")],
                         APP, "engine-registration.txt")
            if "IntegrationTestPlugin" not in wiring:
                raise ValueError("Release activity lacks integration_test registration")
            completion = run([str(analyzer), "dex", "code", "--class", PLUGIN,
                              str(output / "app.apk")], APP, "completion-plugin.txt")
            if not all(value in completion for value in (
                    "plugins.flutter.io/integration_test", "allTestsFinished", "testResults")):
                raise ValueError("Missing SDK completion channel/future in release app")
            runner = run([str(analyzer), "dex", "code", "--class", RUNNER,
                          str(output / "app.apk")], APP, "flutter-test-runner.txt")
            if "IntegrationTestPlugin;->testResults" not in runner:
                raise ValueError("Runner does not read the app's SDK completion future")
            manifest = run([str(analyzer), "manifest", "print", str(output / "test.apk")],
                           APP, "test-manifest.xml")
            if 'android:targetPackage="dev.llamadart.studio"' not in manifest:
                raise ValueError("Instrumentation targets the wrong app")
            test_classes = run([str(analyzer), "dex", "packages", "--defined-only",
                                str(output / "test.apk")], APP, "test-dex-packages.txt")
            if "dev.llamadart.studio.MainActivityTest" not in test_classes:
                raise ValueError("Missing maintained MainActivityTest")
            if PLUGIN in test_classes:
                raise ValueError("Duplicate completion plugin in instrumentation APK")
        generated = APP / "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"
        shutil.copyfile(generated, output / "GeneratedPluginRegistrant.java")
        mapping = APP / "build/app/outputs/mapping/release/mapping.txt"
        shutil.copyfile(mapping, output / "r8-mapping.txt")
        clean()
        if identity is not None and mobile.build_identity(REPO, APP, args.flutter_sdk.resolve(), source, "android") != identity:
            raise ValueError("Build inputs moved during build")
        receipt["status"] = "build-verified-physical-execution-pending"
    except Exception as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error)
        raise
    finally:
        receipt["retained"] = {str(path.relative_to(output)): digest(path)
                               for path in sorted(output.rglob("*")) if path.is_file()}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
