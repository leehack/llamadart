"""Closed local input contract for the separate mobile default workflow suite."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

TARGET = "integration_test/mobile_default_workflows_acceptance_test.dart"
RESOURCE = "studio-mobile-default-models"
ASSETS = {
    "Qwen3.5-0.8B-Q4_K_M.gguf": {
        "bytes": 532517120,
        "sha256": "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
    },
    "Qwen3.5-0.8B-mmproj-F16.gguf": {
        "bytes": 204987232,
        "sha256": "56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453",
    },
}
MANIFEST = {"schema": 1, "assets": ASSETS}


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return {"sha256": hasher.hexdigest(), "bytes": path.stat().st_size}


def validate_manifest(value):
    # Exact equality excludes URLs, extra fields, aliases and traversal paths.
    if (value != MANIFEST or type(value.get("schema")) is not int
            or any(type(asset.get("bytes")) is not int
                   for asset in value["assets"].values())):
        raise ValueError("Mobile default assets must match the exact allowlist")


def verify_stage(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Model stage must be a real directory")
    if {p.name for p in root.iterdir()} != {*ASSETS, "manifest.json"}:
        raise ValueError("Unexpected or missing staged input")
    manifest = root / "manifest.json"
    if manifest.is_symlink() or manifest.stat().st_size > 4096:
        raise ValueError("Unsafe asset manifest")
    validate_manifest(json.loads(manifest.read_text()))
    for name, expected in ASSETS.items():
        path = root / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError("Asset identity mismatch: " + name)


def stage_assets(primary, projector, output):
    output.mkdir(parents=True, exist_ok=False)
    for source, name in zip((primary, projector), ASSETS):
        if not source.is_file() or digest(source) != ASSETS[name]:
            raise ValueError("Source asset identity mismatch: " + name)
        shutil.copyfile(source, output / name)
    (output / "manifest.json").write_text(json.dumps(MANIFEST, indent=2) + "\n")
    verify_stage(output)


def build_identity(repo, app, sdk, source, platform):
    if platform not in ("android", "ios"):
        raise ValueError("Unsupported mobile build platform")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=sdk, text=True).strip():
        raise ValueError("Flutter SDK source must be clean before freezing inputs")
    paths = [app / TARGET, *sorted((app / "integration_test/support").glob("*.dart")),
             repo / "lib/src/hook/native_release_pins.dart"]
    engine = sdk / "bin/cache/artifacts/engine"
    engine_root = engine / ("android-arm64-release" if platform == "android" else "ios-release")
    engine_inputs = sorted(p for p in engine_root.rglob("*") if p.is_file())
    if not any(p.name.startswith("gen_snapshot") for p in engine_inputs):
        raise ValueError("Precache the platform release engine before freezing build inputs")
    sdk_inputs = [sdk / "bin/cache/dart-sdk/bin/dart",
                  sdk / "bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot",
                  sdk / "bin/cache/flutter_tools.snapshot"]
    if not all(p.is_file() for p in sdk_inputs):
        raise ValueError("Prepare the pinned SDK compiler/tool snapshots before freezing inputs")
    sdk_inputs += engine_inputs
    return {"source_commit": source,
            "flutter_revision": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=sdk, text=True).strip(),
            "inputs": {str(p.relative_to(repo)): digest(p) for p in paths},
            "sdk_inputs": {str(p.relative_to(sdk)): digest(p) for p in sdk_inputs}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--primary", required=True, type=Path)
    parser.add_argument("--projector", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    stage_assets(args.primary, args.projector, args.output)
