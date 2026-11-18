#!/usr/bin/env python3
"""Prepare signed iOS Release XCTest products; never execute or upload them."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

import mobile_default_assets as mobile

APP = Path(__file__).resolve().parents[1]
REPO = APP.parents[1]


def build_commands(output, team, identity, models=None, ordinary=False):
    if ordinary and models is not None:
        raise ValueError("Ordinary builds cannot stage models")
    if not ordinary and models is None:
        raise ValueError("Acceptance requires the local model stage")
    config = ["flutter", "build", "ios", "--release", "--config-only", "--no-codesign",
              "--target", "lib/main.dart" if ordinary else mobile.TARGET]
    if not ordinary:
        config += ["--dart-define=STUDIO_MOBILE_DEFAULT_ACCEPTANCE=true",
                   "--dart-define=STUDIO_MOBILE_DEFAULT_IDENTITY=" + json.dumps(identity, separators=(",", ":"))]
    build = ["xcodebuild", "-workspace", "Runner.xcworkspace", "-scheme", "Runner",
             "-configuration", "Release", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
             "-derivedDataPath", str(output / "derived"), "build" if ordinary else "build-for-testing",
             "DEVELOPMENT_TEAM=" + team, "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
             "STUDIO_MOBILE_DEFAULT_ACCEPTANCE=" + ("NO" if ordinary else "YES")]
    if not ordinary:
        build.append("STUDIO_MOBILE_DEFAULT_MODELS=" + str(models.resolve()))
    return config, build


def check_payloads(app, ordinary):
    resource = app / mobile.RESOURCE
    if ordinary:
        if resource.exists() or any(p.suffix in (".gguf", ".xctest") or "qualification" in p.name
                                    for p in app.rglob("*")):
            raise ValueError("Ordinary app contains qualification/model payloads")
    else:
        mobile.verify_stage(resource)
        allowed = {resource / name for name in mobile.ASSETS}
        if {p for p in app.rglob("*.gguf")} != allowed:
            raise ValueError("Unexpected model in iOS app")
    if any("kernel_blob" in p.name for p in app.rglob("*")):
        raise ValueError("Release app contains a kernel blob")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--team", required=True, help="Existing admitted Apple signing team")
    parser.add_argument("--models", type=Path)
    parser.add_argument("--ordinary", action="store_true")
    args = parser.parse_args()
    if (args.models is None) != args.ordinary:
        parser.error("Use --models for acceptance or --ordinary without models")
    if args.models:
        mobile.verify_stage(args.models)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    for key in ("STUDIO_MOBILE_DEFAULT_ACCEPTANCE", "STUDIO_MOBILE_DEFAULT_MODELS",
                "FLUTTER_TARGET", "DART_DEFINES", "CODE_SIGNING_ALLOWED"):
        if key in env:
            raise ValueError("Unset inherited build input: " + key)
    env["PATH"] = os.pathsep.join([str(args.flutter_sdk.resolve() / "bin"), env["PATH"]])
    receipt = {"qualified": False, "deviceExecuted": False, "ordinary": args.ordinary,
               "commands": [], "status": "building"}

    def run(command, cwd, name):
        receipt["commands"].append({"argv": list(map(str, command)), "log": name})
        result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
        (output / name).write_text(result.stdout)
        (output / (name + ".stderr")).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"{name}: exit {result.returncode}")
        return result.stdout

    def clean():
        if subprocess.check_output(["git", "status", "--porcelain"], cwd=REPO, text=True).strip():
            raise ValueError("Commit source changes before a provenance build")

    try:
        clean()
        source = run(["git", "rev-parse", "HEAD"], REPO, "source.txt").strip()
        receipt["source"] = source
        receipt["tree"] = run(["git", "rev-parse", "HEAD^{tree}"], REPO, "tree.txt").strip()
        for tool in ("flutter", "dart"):
            if Path(shutil.which(tool, path=env["PATH"])).resolve() != (args.flutter_sdk / "bin" / tool).resolve():
                raise ValueError("Wrong bare SDK tool: " + tool)
        version = json.loads(run(["flutter", "--version", "--machine"], APP, "flutter-version.json"))
        if version["frameworkVersion"] != (APP / ".flutter-version").read_text().strip():
            raise ValueError("Flutter SDK does not match Studio pin")
        run(["dart", "--version"], APP, "dart-version.txt")
        run(["xcodebuild", "-version"], APP, "xcode-version.txt")
        identity = mobile.build_identity(REPO, APP, args.flutter_sdk.resolve(), source, "ios")
        receipt["identity"] = identity
        subprocess.run(["git", "archive", "--format=tar", "-o", str(output / "source.tar"), source],
                       cwd=REPO, check=True)
        models = None
        if args.models:
            models = output / mobile.RESOURCE
            shutil.copytree(args.models, models)
            mobile.verify_stage(models)
        run(["dart", "pub", "get"], APP.parent / "llamadart_studio_core", "resolve-core.log")
        run(["flutter", "pub", "get"], APP, "resolve-ui.log")
        clean()
        config, build = build_commands(output, args.team, identity, models, args.ordinary)
        run(config, APP, "configure.log")
        run(build, APP / "ios", "build.log")
        products = output / "derived/Build/Products"
        app = products / "Release-iphoneos/Runner.app"
        check_payloads(app, args.ordinary)
        run(["codesign", "--verify", "--deep", "--strict", str(app)], APP, "app-signature.txt")
        run(["codesign", "-d", "--verbose=4", str(app)], APP, "app-signing-identity.txt")
        binary = app / "Frameworks/App.framework/App"
        if run(["lipo", "-archs", str(binary)], APP, "aot-architecture.txt").strip() != "arm64":
            raise ValueError("Expected arm64 AOT App.framework")
        if not args.ordinary:
            tests = app / "PlugIns/RunnerTests.xctest"
            run(["codesign", "--verify", "--strict", str(tests)], APP, "test-signature.txt")
            run(["codesign", "-d", "--verbose=4", str(tests)], APP, "test-signing-identity.txt")
            for name in ("app", "test"):
                text = (output / (name + "-signing-identity.txt.stderr")).read_text()
                if "TeamIdentifier=" + args.team not in text or "Signature=adhoc" in text:
                    raise ValueError("Unexpected signing team or ad hoc signature")
            xctestruns = list(products.glob("*.xctestrun"))
            if len(xctestruns) != 1:
                raise ValueError("Expected exactly one XCTest run manifest")
            manifest = plistlib.loads(xctestruns[0].read_bytes())
            if "RunnerTests" not in str(manifest):
                raise ValueError("Missing maintained RunnerTests")
        if mobile.build_identity(REPO, APP, args.flutter_sdk.resolve(), source, "ios") != identity:
            raise ValueError("Build inputs moved during build")
        clean()
        receipt["status"] = "build-verified-physical-execution-pending"
    except Exception as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error)
        raise
    finally:
        receipt["retained"] = {str(p.relative_to(output)): mobile.digest(p)
                               for p in sorted(output.rglob("*")) if p.is_file()}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
